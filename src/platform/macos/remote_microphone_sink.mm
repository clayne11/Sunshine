/**
 * @file src/platform/macos/remote_microphone_sink.mm
 * @brief Explicit-output macOS sink for remote microphone PCM.
 */
#import "remote_microphone_sink.h"

// platform includes
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>

// standard includes
#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <vector>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/macos/av_audio.h"
#include "src/platform/macos/coreaudio_helpers.h"
#include "src/platform/macos/remote_microphone_ring.h"

namespace platf::remote_microphone {
  namespace {
    constexpr Float64 kSampleRate = 48000.0;  ///< Remote microphone sample rate.
    constexpr UInt32 kChannels = 2;  ///< Stereo output channel count.
    constexpr auto kTelemetryEarlyWindow = std::chrono::seconds {60};  ///< Initial interval during which sink reports are more frequent.
    constexpr auto kTelemetryEarlyReportInterval = std::chrono::seconds {10};  ///< Minimum interval between early sink reports.
    constexpr auto kTelemetryReportInterval = std::chrono::seconds {30};  ///< Minimum interval between steady-state sink reports.

    /**
     * @brief Return the actual callback-entry timestamp for gap measurement.
     * @return Mach absolute-time ticks sampled at callback entry.
     */
    std::uint64_t callback_host_time() noexcept {
      return mach_absolute_time();
    }

    /**
     * @brief Convert mach absolute-time ticks to milliseconds for reporting.
     * @param ticks Mach absolute-time ticks.
     * @return Elapsed milliseconds, or zero when the timebase is unavailable.
     */
    double ticks_to_milliseconds(std::uint64_t ticks) noexcept {
      mach_timebase_info_data_t timebase {};
      if (ticks == 0 || mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        return 0.0;
      }
      const auto nanoseconds = static_cast<long double>(ticks) * timebase.numer / timebase.denom;
      return static_cast<double>(nanoseconds / 1'000'000.0L);
    }

    /**
     * @brief Find a Core Audio device by exact UID.
     */
    AudioDeviceID find_device(const std::string &uid) noexcept {
      if (uid.empty()) {
        return kAudioObjectUnknown;
      }

      CFStringRef requestedUID = CFStringCreateWithCString(nullptr, uid.c_str(), kCFStringEncodingUTF8);
      if (!requestedUID) {
        return kAudioObjectUnknown;
      }

      AudioObjectPropertyAddress devicesAddress {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
      };
      UInt32 dataSize = 0;
      AudioDeviceID result = kAudioObjectUnknown;
      if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddress, 0, nullptr, &dataSize) == noErr && dataSize >= sizeof(AudioDeviceID)) {
        std::vector<AudioDeviceID> devices(dataSize / sizeof(AudioDeviceID));
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddress, 0, nullptr, &dataSize, devices.data()) == noErr) {
          for (const auto device : devices) {
            AudioObjectPropertyAddress uidAddress {
              .mSelector = kAudioDevicePropertyDeviceUID,
              .mScope = kAudioObjectPropertyScopeGlobal,
              .mElement = kAudioObjectPropertyElementMain,
            };
            CFStringRef deviceUID = nullptr;
            UInt32 uidSize = sizeof(deviceUID);
            const bool matches = AudioObjectGetPropertyData(device, &uidAddress, 0, nullptr, &uidSize, &deviceUID) == noErr && deviceUID && CFStringCompare(requestedUID, deviceUID, 0) == kCFCompareEqualTo;
            if (deviceUID) {
              CFRelease(deviceUID);
            }
            if (matches) {
              result = device;
              break;
            }
          }
        }
      }

      CFRelease(requestedUID);
      return result;
    }

    /**
     * @brief Query the number of output channels exposed by a device.
     */
    bool query_output_channels(AudioDeviceID device, UInt32 &channels) noexcept {
      channels = 0;
      if (device == kAudioObjectUnknown) {
        return false;
      }

      AudioObjectPropertyAddress address {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = kAudioDevicePropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain,
      };
      UInt32 dataSize = 0;
      if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &dataSize) != noErr || dataSize < sizeof(AudioBufferList)) {
        return false;
      }

      std::vector<std::byte> storage(dataSize);
      auto *bufferList = reinterpret_cast<AudioBufferList *>(storage.data());
      if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &dataSize, bufferList) != noErr || bufferList->mNumberBuffers == 0) {
        return false;
      }

      for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        channels += bufferList->mBuffers[index].mNumberChannels;
      }
      return channels > 0;
    }

    /**
     * @brief Check whether the configured host capture name identifies a sink device.
     *
     * macOS stores Sunshine's configured audio sink as the localized capture
     * device name while this receiver is selected by exact Core Audio UID.  A
     * matching Core Audio device name is therefore treated as the same device.
     * If Core Audio cannot report the name, the result is conservative so that
     * a possibly shared device is not opened while host capture is active.
     *
     * @param device Core Audio output device selected for remote microphone audio.
     * @return True when the configured capture device may be the selected output.
     */
    bool configured_capture_uses_device(AudioDeviceID device) noexcept {
      if (config::audio.sink.empty()) {
        return false;
      }

      CFStringRef configuredName = CFStringCreateWithCString(nullptr, config::audio.sink.c_str(), kCFStringEncodingUTF8);
      if (!configuredName) {
        return true;
      }

      AudioObjectPropertyAddress nameAddress {
        .mSelector = kAudioDevicePropertyDeviceNameCFString,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
      };
      CFStringRef deviceName = nullptr;
      UInt32 nameSize = sizeof(deviceName);
      const auto status = AudioObjectGetPropertyData(device, &nameAddress, 0, nullptr, &nameSize, &deviceName);
      const bool matches = status != noErr || !deviceName || CFStringCompare(configuredName, deviceName, 0) == kCFCompareEqualTo;
      if (deviceName) {
        CFRelease(deviceName);
      }
      CFRelease(configuredName);
      return matches;
    }

    /**
     * @brief HAL output unit sink pinned to one Core Audio device.
     */
    class hal_sink_t final: public sink_t {
    public:
      /**
       * @brief Construct and fully start a device-pinned output unit.
       * @param device Core Audio device ID already resolved from the requested UID.
       * @param requires_process_exclusion Whether system-tap exclusion gates this sink.
       */
      explicit hal_sink_t(AudioDeviceID device, bool requires_process_exclusion):
          device_(device),
          requiresProcessExclusion_(requires_process_exclusion) {
        ready_ = initialize();
      }

      /**
       * @brief Stop and dispose the output unit.
       */
      ~hal_sink_t() override {
        if (started_) {
          AudioOutputUnitStop(outputUnit_);
        }
        if (initialized_) {
          AudioUnitUninitialize(outputUnit_);
        }
        if (outputUnit_) {
          AudioComponentInstanceDispose(outputUnit_);
        }
        report_telemetry(true);
      }

      /**
       * @brief Check whether Core Audio accepted the output setup.
       */
      bool ready() const noexcept {
        return ready_;
      }

      /**
       * @brief Convert and queue a mono microphone chunk.
       */
      bool write(std::span<const std::int16_t> mono48k) override {
        if (!ready_) {
          telemetry_.record_input_rejection(mono48k.size());
          return false;
        }
        if (requiresProcessExclusion_ && !platf::system_audio_tap_excludes_sunshine()) {
          telemetry_.record_input_rejection(mono48k.size());
          return false;
        }
        const auto written_samples = ring_.write_count(mono48k);
        telemetry_.record_ring_write(written_samples, mono48k.size() - written_samples);
        return written_samples == mono48k.size();
      }

      /**
       * @brief Emit rate-limited sink telemetry from a worker context.
       */
      void report_telemetry() override {
        report_telemetry(false);
      }

    private:
      /**
       * @brief Fill one HAL output callback from the bounded ring.
       */
      static OSStatus render_callback(void *refCon, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frameCount, AudioBufferList *ioData) noexcept {
        auto *sink = static_cast<hal_sink_t *>(refCon);
        if (!sink) {
          return noErr;
        }

        sink->telemetry_.record_callback(frameCount, callback_host_time());
        if (!ioData || ioData->mNumberBuffers == 0) {
          sink->telemetry_.record_format_anomaly();
          sink->telemetry_.record_render(0, frameCount);
          return noErr;
        }

        for (UInt32 index = 0; index < ioData->mNumberBuffers; ++index) {
          if (ioData->mBuffers[index].mData && ioData->mBuffers[index].mDataByteSize > 0) {
            std::memset(ioData->mBuffers[index].mData, 0, ioData->mBuffers[index].mDataByteSize);
          }
        }

        bool format_anomaly = ioData->mNumberBuffers > 2;
        if (ioData->mNumberBuffers == 1) {
          const auto &buffer = ioData->mBuffers[0];
          format_anomaly = format_anomaly || !buffer.mData || buffer.mNumberChannels != kChannels || buffer.mDataByteSize < static_cast<std::size_t>(frameCount) * kChannels * sizeof(float);
        } else if (ioData->mNumberBuffers >= 2) {
          const auto &left = ioData->mBuffers[0];
          const auto &right = ioData->mBuffers[1];
          format_anomaly = format_anomaly || !left.mData || !right.mData || left.mNumberChannels != 1 || right.mNumberChannels != 1 || left.mDataByteSize < static_cast<std::size_t>(frameCount) * sizeof(float) || right.mDataByteSize < static_cast<std::size_t>(frameCount) * sizeof(float);
        }
        if (format_anomaly) {
          sink->telemetry_.record_format_anomaly();
        }

        if (sink->requiresProcessExclusion_ && !platf::system_audio_tap_excludes_sunshine()) {
          sink->telemetry_.record_exclusion_mute(frameCount);
          sink->ring_.discard();
          return noErr;
        }

        UInt32 read_frames = 0;
        if (ioData->mNumberBuffers == 1 && ioData->mBuffers[0].mData) {
          const auto capacity = static_cast<UInt32>(ioData->mBuffers[0].mDataByteSize / (detail::pcm_ring_t::channels * sizeof(float)));
          read_frames = sink->ring_.read_interleaved(static_cast<float *>(ioData->mBuffers[0].mData), std::min(frameCount, capacity));
        } else if (ioData->mNumberBuffers >= 2 && ioData->mBuffers[0].mData && ioData->mBuffers[1].mData) {
          const auto capacity = static_cast<UInt32>(std::min(ioData->mBuffers[0].mDataByteSize, ioData->mBuffers[1].mDataByteSize) / sizeof(float));
          read_frames = sink->ring_.read_planar(static_cast<float *>(ioData->mBuffers[0].mData), static_cast<float *>(ioData->mBuffers[1].mData), std::min(frameCount, capacity));
        }
        sink->telemetry_.record_render(read_frames, frameCount - read_frames);
        return noErr;
      }

      /**
       * @brief Report telemetry when forced or after the periodic interval.
       * @param force Emit a final report even when the interval has not elapsed.
       */
      void report_telemetry(bool force) {
        const auto now = std::chrono::steady_clock::now();
        if (!force) {
          const auto since_start = now - telemetry_started_at_;
          const auto interval = since_start < kTelemetryEarlyWindow ? kTelemetryEarlyReportInterval : kTelemetryReportInterval;
          const auto since_last = last_telemetry_report_ == std::chrono::steady_clock::time_point {} ? since_start : now - last_telemetry_report_;
          if (since_last < interval) {
            return;
          }
        }
        last_telemetry_report_ = now;
        BOOST_LOG(info) << "Remote microphone sink telemetry: callbacks=" << telemetry_.callback_count.load(std::memory_order_relaxed)
                        << ", requested_frames=" << telemetry_.callback_requested_frames.load(std::memory_order_relaxed)
                        << ", read_frames=" << telemetry_.callback_read_frames.load(std::memory_order_relaxed)
                        << ", underrun_frames=" << telemetry_.callback_underrun_frames.load(std::memory_order_relaxed)
                        << ", max_callback_gap_ms=" << ticks_to_milliseconds(telemetry_.callback_max_gap_ticks.load(std::memory_order_relaxed))
                        << ", format_anomalies=" << telemetry_.format_anomalies.load(std::memory_order_relaxed)
                        << ", exclusion_muted_frames=" << telemetry_.exclusion_muted_frames.load(std::memory_order_relaxed)
                        << ", ring_written_samples=" << telemetry_.ring_written_samples.load(std::memory_order_relaxed)
                        << ", ring_dropped_samples=" << telemetry_.ring_dropped_samples.load(std::memory_order_relaxed)
                        << ", input_rejected_samples=" << telemetry_.input_rejected_samples.load(std::memory_order_relaxed);
      }

      /**
       * @brief Verify output capability, configure the HAL unit, and start it.
       */
      bool initialize() {
        UInt32 outputChannels = 0;
        if (!ring_.valid() || !query_output_channels(device_, outputChannels)) {
          BOOST_LOG(warning) << "Remote microphone output device has no usable output stream.";
          return false;
        }

        AudioComponentDescription description {
          .componentType = kAudioUnitType_Output,
          .componentSubType = kAudioUnitSubType_HALOutput,
          .componentManufacturer = kAudioUnitManufacturer_Apple,
          .componentFlags = 0,
          .componentFlagsMask = 0,
        };
        const auto component = AudioComponentFindNext(nullptr, &description);
        if (!component || AudioComponentInstanceNew(component, &outputUnit_) != noErr) {
          BOOST_LOG(warning) << "Unable to create the macOS HAL output unit for the remote microphone.";
          return false;
        }

        UInt32 enable = 1;
        UInt32 disable = 0;
        if (AudioUnitSetProperty(outputUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof(enable)) != noErr || AudioUnitSetProperty(outputUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, sizeof(disable)) != noErr || AudioUnitSetProperty(outputUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device_, sizeof(device_)) != noErr) {
          BOOST_LOG(warning) << "Unable to pin the remote microphone output to the selected macOS device.";
          return false;
        }

        AURenderCallbackStruct callback {
          .inputProc = render_callback,
          .inputProcRefCon = this,
        };
        if (AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) {
          BOOST_LOG(warning) << "Unable to install the remote microphone render callback.";
          return false;
        }

        AudioStreamBasicDescription format {
          .mSampleRate = kSampleRate,
          .mFormatID = kAudioFormatLinearPCM,
          .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
          .mBytesPerPacket = kChannels * sizeof(float),
          .mFramesPerPacket = 1,
          .mBytesPerFrame = kChannels * sizeof(float),
          .mChannelsPerFrame = kChannels,
          .mBitsPerChannel = 32,
          .mReserved = 0,
        };
        if (AudioUnitSetProperty(outputUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) != noErr) {
          BOOST_LOG(warning) << "Selected macOS output device rejected the 48 kHz stereo float format.";
          return false;
        }

        if (AudioUnitInitialize(outputUnit_) != noErr) {
          BOOST_LOG(warning) << "Unable to initialize the remote microphone HAL output unit.";
          return false;
        }
        initialized_ = true;

        if (AudioOutputUnitStart(outputUnit_) != noErr) {
          BOOST_LOG(warning) << "Unable to start the remote microphone HAL output unit.";
          return false;
        }
        started_ = true;
        return true;
      }

      AudioDeviceID device_ {kAudioObjectUnknown};  ///< Explicit Core Audio output device ID.
      AudioUnit outputUnit_ {};  ///< HAL output unit pinned to device_.
      detail::pcm_ring_t ring_;  ///< Bounded producer-to-render PCM ring.
      detail::sink_telemetry_t telemetry_;  ///< Lock-free callback and ring counters.
      bool initialized_ {false};  ///< Whether AudioUnitInitialize succeeded.
      bool started_ {false};  ///< Whether AudioOutputUnitStart succeeded.
      bool ready_ {false};  ///< Whether the sink can accept remote microphone samples.
      bool requiresProcessExclusion_ {false};  ///< Whether writes require a safe system-tap exclusion.
      std::chrono::steady_clock::time_point telemetry_started_at_ {std::chrono::steady_clock::now()};  ///< Start of the sink telemetry schedule.
      std::chrono::steady_clock::time_point last_telemetry_report_ {};  ///< Last periodic report time, accessed outside the render callback.
    };
  }  // namespace

  sink_t::~sink_t() = default;

  bool available(const std::string &uid) {
    UInt32 channels = 0;
    return query_output_channels(find_device(uid), channels);
  }

  std::unique_ptr<sink_t> make_sink(const std::string &uid) {
    const auto device = find_device(uid);
    UInt32 channels = 0;
    if (!query_output_channels(device, channels)) {
      BOOST_LOG(warning) << "Remote microphone output device UID is unavailable or has no output stream.";
      return nullptr;
    }

    if (config::audio.stream && !config::audio.sink.empty() && configured_capture_uses_device(device)) {
      BOOST_LOG(warning) << "Configured remote microphone output matches the host capture device; refusing to open it to prevent audio feedback.";
      return nullptr;
    }

    const bool requires_process_exclusion = config::audio.stream && config::audio.sink.empty();
    auto sink = std::unique_ptr<hal_sink_t>(new (std::nothrow) hal_sink_t(device, requires_process_exclusion));
    if (!sink || !sink->ready()) {
      return nullptr;
    }
    return sink;
  }
}  // namespace platf::remote_microphone
