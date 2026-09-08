/**
 * @file src/platform/macos/remote_microphone_sink.mm
 * @brief Explicit-output macOS sink for remote microphone PCM.
 */
#import "remote_microphone_sink.h"

// platform includes
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>

// standard includes
#include <algorithm>
#include <cstddef>
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
        if (!ready_ || (requiresProcessExclusion_ && !platf::system_audio_tap_excludes_sunshine())) {
          return false;
        }
        return ring_.write(mono48k);
      }

    private:
      /**
       * @brief Fill one HAL output callback from the bounded ring.
       */
      static OSStatus render_callback(void *refCon, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frameCount, AudioBufferList *ioData) noexcept {
        auto *sink = static_cast<hal_sink_t *>(refCon);
        if (!sink || !ioData || ioData->mNumberBuffers == 0) {
          return noErr;
        }

        for (UInt32 index = 0; index < ioData->mNumberBuffers; ++index) {
          if (ioData->mBuffers[index].mData && ioData->mBuffers[index].mDataByteSize > 0) {
            std::memset(ioData->mBuffers[index].mData, 0, ioData->mBuffers[index].mDataByteSize);
          }
        }

        if (sink->requiresProcessExclusion_ && !platf::system_audio_tap_excludes_sunshine()) {
          sink->ring_.discard();
          return noErr;
        }

        if (ioData->mNumberBuffers == 1 && ioData->mBuffers[0].mData) {
          const auto capacity = static_cast<UInt32>(ioData->mBuffers[0].mDataByteSize / (detail::pcm_ring_t::channels * sizeof(float)));
          sink->ring_.read_interleaved(static_cast<float *>(ioData->mBuffers[0].mData), std::min(frameCount, capacity));
        } else if (ioData->mNumberBuffers >= 2 && ioData->mBuffers[0].mData && ioData->mBuffers[1].mData) {
          const auto capacity = static_cast<UInt32>(std::min(ioData->mBuffers[0].mDataByteSize, ioData->mBuffers[1].mDataByteSize) / sizeof(float));
          sink->ring_.read_planar(static_cast<float *>(ioData->mBuffers[0].mData), static_cast<float *>(ioData->mBuffers[1].mData), std::min(frameCount, capacity));
        }
        return noErr;
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
      bool initialized_ {false};  ///< Whether AudioUnitInitialize succeeded.
      bool started_ {false};  ///< Whether AudioOutputUnitStart succeeded.
      bool ready_ {false};  ///< Whether the sink can accept remote microphone samples.
      bool requiresProcessExclusion_ {false};  ///< Whether writes require a safe system-tap exclusion.
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
