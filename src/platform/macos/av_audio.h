/**
 * @file src/platform/macos/av_audio.h
 * @brief Declarations for macOS audio capture with dual input paths.
 *
 * This header defines the AVAudio class which provides distinct audio capture methods:
 * 1. **Microphone capture** - Uses AVFoundation framework to capture from specific microphone devices
 * 2. **System-wide audio tap** - Uses Core Audio taps to capture all system audio output (macOS 14.0+)
 *
 * The system-wide audio tap allows capturing audio from all applications and system sounds,
 * while microphone capture focuses on input from physical or virtual microphone devices.
 */
#pragma once

// platform includes
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CoreAudio.h>

// standard includes
#include <atomic>
#include <cstdint>
#include <functional>
#include <limits>

// lib includes
#include "third-party/TPCircularBuffer/TPCircularBuffer.h"

NS_ASSUME_NONNULL_BEGIN

// Forward declarations
@class AVAudio;
@class CATapDescription;

namespace platf {
  using microphone_permission_callback_t = std::function<void(bool)>;  ///< Completion callback for a microphone permission request.
  using microphone_permission_request_t = std::function<void(microphone_permission_callback_t)>;  ///< Function that starts a microphone permission request.

  /**
   * @brief Resolve microphone access from an AVFoundation authorization state.
   *
   * @param authorization_status Current authorization state for audio capture.
   * @param request_access Function used to request access when authorization has not been determined.
   * @return `true` when microphone access is authorized.
   */
  bool request_microphone_permission(AVAuthorizationStatus authorization_status, const microphone_permission_request_t &request_access);

  /**
   * @brief Ensure Sunshine has permission to capture microphone audio.
   *
   * Requests access and waits for the user's response when authorization has not yet been determined.
   *
   * @return `true` when microphone access is authorized.
   */
  bool request_microphone_permission();

  /**
   * @brief Provide captured PCM frames to AudioConverter.
   *
   * @param inAudioConverter In audio converter.
   * @param ioNumberDataPackets Requested and returned packet count.
   * @param ioData Buffer list filled with input audio.
   * @param outDataPacketDescription Optional packet description output.
   * @param inUserData AudioConverterInputData state used by the callback.
   * @return Core Audio status code from the callback.
   */
  OSStatus audioConverterComplexInputProc(AudioConverterRef _Nullable inAudioConverter, UInt32 *_Nonnull ioNumberDataPackets, AudioBufferList *_Nonnull ioData, AudioStreamPacketDescription *_Nullable *_Nullable outDataPacketDescription, void *_Nonnull inUserData);
  /**
   * @brief Receive system-audio tap samples from Core Audio.
   *
   * @param inDevice In device.
   * @param inNow In now.
   * @param inInputData In input data.
   * @param inInputTime In input time.
   * @param outOutputData Out output data.
   * @param inOutputTime In output time.
   * @param inClientData In client data.
   * @return Core Audio status code from the IO callback.
   */
  OSStatus systemAudioIOProc(AudioObjectID inDevice, const AudioTimeStamp *_Nullable inNow, const AudioBufferList *_Nullable inInputData, const AudioTimeStamp *_Nullable inInputTime, AudioBufferList *_Nullable outOutputData, const AudioTimeStamp *_Nullable inOutputTime, void *_Nullable inClientData);
}  // namespace platf

/**
 * @brief Data structure for AudioConverter input callback.
 * Contains audio data and metadata needed for format conversion during audio processing.
 */
struct AudioConverterInputData {
  float *inputData;  ///< Pointer to input audio data
  UInt32 inputFrames;  ///< Total number of input frames available
  UInt32 framesProvided;  ///< Number of frames already provided to converter
  UInt32 deviceChannels;  ///< Number of channels in the device audio
  AVAudio *avAudio;  ///< Reference to the AVAudio instance
};

/**
 * @brief Lock-free, bounded diagnostics for a macOS audio capture session.
 *
 * The Core Audio IOProc updates only atomics in this structure.  It never logs,
 * allocates, or performs Objective-C work.  The consumer thread reports a
 * single aggregate record after the first telemetry window or during cleanup.
 */
struct AVAudioTelemetry {
  static constexpr UInt32 unknown_value = std::numeric_limits<UInt32>::max();  ///< Sentinel for unavailable Core Audio properties.
  static constexpr std::uint64_t window_seconds = 30;  ///< Maximum duration of one diagnostic window.

  UInt32 requestedSampleRate {};  ///< Requested client sample rate in hertz.
  UInt32 requestedFrameSize {};  ///< Requested client frames per packet.
  UInt32 requestedChannels {};  ///< Requested client channel count.
  Float64 aggregateSampleRate {};  ///< Aggregate device sample rate in hertz.
  UInt32 aggregateChannels {unknown_value};  ///< Aggregate device channel count.
  UInt32 actualBufferFrameSize {unknown_value};  ///< Aggregate device callback buffer size in frames.
  UInt32 aggregateLatencyFrames {unknown_value};  ///< Aggregate device reported latency in frames.
  UInt32 aggregateSafetyOffsetFrames {unknown_value};  ///< Aggregate device reported safety offset in frames.
  std::uint64_t startHostTime {};  ///< Host-time tick at which collection began.
  std::uint64_t deadlineHostTime {};  ///< Host-time tick at which collection expires.

  std::atomic_bool collecting {false};  ///< Whether the bounded window is active.
  std::atomic_bool reported {false};  ///< Whether the aggregate record has been emitted.

  std::atomic<std::uint64_t> callbackCount {0};  ///< Number of callbacks observed.
  std::atomic<std::uint64_t> callbackFrames {0};  ///< Total frames in valid callbacks.
  std::atomic<UInt32> callbackMinFrames {unknown_value};  ///< Smallest valid callback frame count.
  std::atomic<UInt32> callbackMaxFrames {0};  ///< Largest valid callback frame count.
  std::atomic<UInt32> callbackMaxBufferBytes {0};  ///< Largest first-buffer byte count.
  std::atomic<UInt32> callbackMaxBufferCount {0};  ///< Largest number of buffers in a callback.
  std::atomic<std::uint64_t> callbackInvalidCount {0};  ///< Number of callbacks without valid input frames.

  std::atomic<std::uint64_t> callbackPeriodCount {0};  ///< Number of measured callback intervals.
  std::atomic<std::uint64_t> callbackPeriodTicks {0};  ///< Sum of callback intervals in host ticks.
  std::atomic<std::uint64_t> callbackMaxPeriodTicks {0};  ///< Largest callback interval in host ticks.
  std::atomic<std::uint64_t> lastCallbackHostTime {0};  ///< Host-time tick of the previous callback.

  std::atomic<std::uint64_t> timestampAgeCount {0};  ///< Number of valid, non-future input timestamps.
  std::atomic<std::uint64_t> timestampMaxAgeTicks {0};  ///< Largest callback-to-input timestamp age.
  std::atomic<std::uint64_t> timestampFutureCount {0};  ///< Number of input timestamps ahead of callback time.

  std::atomic<std::uint64_t> producerWriteCount {0};  ///< Number of successful circular-buffer writes.
  std::atomic<std::uint64_t> producerDropCount {0};  ///< Number of failed circular-buffer writes.
  std::atomic<UInt32> maxObservedFillBytes {0};  ///< Largest fill observed by the consumer before a read.

  std::atomic<std::uint64_t> consumerEmptyCount {0};  ///< Number of consumer reads that found no bytes.
  std::atomic<std::uint64_t> consumerWaitCount {0};  ///< Number of semaphore waits by the consumer.
  std::atomic<std::uint64_t> consumerTimeoutCount {0};  ///< Number of consumer waits that timed out.
  std::atomic<std::uint64_t> consumerMaxWaitTicks {0};  ///< Largest consumer wait in host ticks.
};

/**
 * @brief IOProc client data structure for Core Audio system taps.
 * Contains configuration and conversion data for real-time audio processing.
 */
typedef struct {
  AVAudio *avAudio;  ///< Reference to AVAudio instance
  AVAudioTelemetry *_Nullable telemetry;  ///< Lock-free diagnostics shared with the consumer thread
  UInt32 clientRequestedChannels;  ///< Number of channels requested by client
  UInt32 clientRequestedSampleRate;  ///< Sample rate requested by client
  UInt32 clientRequestedFrameSize;  ///< Frame size requested by client
  UInt32 aggregateDeviceSampleRate;  ///< Sample rate of the aggregate device
  UInt32 aggregateDeviceChannels;  ///< Number of channels in aggregate device
  Float64 actualAggregateDeviceSampleRate;  ///< Full precision sample rate reported by Core Audio
  UInt32 actualBufferFrameSize;  ///< Buffer frame size reported by Core Audio
  UInt32 aggregateLatencyFrames;  ///< Aggregate device latency in frames
  UInt32 aggregateSafetyOffsetFrames;  ///< Aggregate device safety offset in frames
  AudioConverterRef _Nullable audioConverter;  ///< Audio converter for format conversion
  float *_Nullable conversionBuffer;  ///< Pre-allocated buffer for audio conversion
  UInt32 conversionBufferSize;  ///< Size of the conversion buffer in bytes
} AVAudioIOProcData;

/**
 * @brief Core Audio capture class for macOS audio input and system-wide audio tapping.
 * Provides functionality for both microphone capture via AVFoundation and system-wide
 * audio capture via Core Audio taps (requires macOS 14.0+).
 */
@interface AVAudio: NSObject <AVCaptureAudioDataOutputSampleBufferDelegate> {
@public
  TPCircularBuffer audioSampleBuffer;  ///< Shared circular buffer for both audio capture paths
  dispatch_semaphore_t audioSemaphore;  ///< Real-time safe semaphore for signaling audio sample availability
@private
  // System-wide audio tap components (Core Audio)
  AudioObjectID tapObjectID;  ///< Core Audio tap object identifier for system audio capture
  AudioObjectID aggregateDeviceID;  ///< Aggregate device ID for system tap audio routing
  AudioDeviceIOProcID ioProcID;  ///< IOProc identifier for real-time audio processing
  AVAudioIOProcData *_Nullable ioProcData;  ///< Context data for IOProc callbacks and format conversion
  AVAudioTelemetry *_Nullable audioTelemetry;  ///< Bounded diagnostics for the active audio session
}

// AVFoundation microphone capture properties
@property (nonatomic, assign, nullable) AVCaptureSession *audioCaptureSession;  ///< AVFoundation capture session for microphone input
@property (nonatomic, assign, nullable) AVCaptureConnection *audioConnection;  ///< Audio connection within the capture session
@property (nonatomic, assign) BOOL hostAudioEnabled;  ///< Whether host audio playback should be enabled (affects tap mute behavior)

/**
 * @brief Get all available microphone devices on the system.
 * @return Array of AVCaptureDevice objects representing available microphones
 */
+ (NSArray<AVCaptureDevice *> *)microphones;

/**
 * @brief Get names of all available microphone devices.
 * @return Array of NSString objects with microphone device names
 */
+ (NSArray<NSString *> *)microphoneNames;

/**
 * @brief Find a specific microphone device by name.
 * @param name The name of the microphone to find (nullable - will return nil if name is nil)
 * @return AVCaptureDevice object if found, nil otherwise
 */
+ (nullable AVCaptureDevice *)findMicrophone:(nullable NSString *)name;

/**
 * @brief Sets up microphone capture using AVFoundation framework.
 * @param device The AVCaptureDevice to use for audio input (nullable - will return error if nil)
 * @param sampleRate Target sample rate in Hz
 * @param frameSize Number of frames per buffer
 * @param channels Number of audio channels (1=mono, 2=stereo)
 * @return 0 on success, -1 on failure
 */
- (int)setupMicrophone:(nullable AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

/**
 * @brief Sets up system-wide audio tap for capturing all system audio.
 * Requires macOS 14.0+ and appropriate permissions.
 * @param sampleRate Target sample rate in Hz
 * @param frameSize Number of frames per buffer
 * @param channels Number of audio channels
 * @return 0 on success, -1 on failure
 */
- (int)setupSystemTap:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

// Buffer management methods for testing and internal use
/**
 * @brief Initializes the circular audio buffer for the specified number of channels.
 * @param channels Number of audio channels to configure the buffer for
 */
- (void)initializeAudioBuffer:(UInt8)channels;

/**
 * @brief Start bounded audio telemetry for the active capture configuration.
 *
 * @param sampleRate Requested sample rate in Hz
 * @param frameSize Requested frames per audio packet
 * @param channels Requested channel count
 */
- (void)configureAudioTelemetry:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

/**
 * @brief Refresh aggregate device properties used by audio telemetry.
 *
 * This method is intended for setup code after the aggregate device exists;
 * it must not be called from the Core Audio IOProc.
 */
- (void)refreshAudioTelemetryDeviceProperties;

/**
 * @brief Record bytes observed by the audio consumer.
 * @param availableBytes Bytes available before the consumer read.
 */
- (void)recordAudioConsumerAvailableBytes:(UInt32)availableBytes;

/**
 * @brief Record a consumer wait without logging from the producer callback.
 * @param waitHostTicks Monotonic host-time ticks spent waiting.
 * @param timedOut Whether the wait reached its timeout.
 */
- (void)recordAudioConsumerWait:(std::uint64_t)waitHostTicks timedOut:(BOOL)timedOut;

/**
 * @brief Emit one aggregate telemetry record when the bounded window expires.
 * @param force Emit immediately during teardown.
 */
- (void)reportAudioTelemetryIfDue:(BOOL)force;

/**
 * @brief Cleans up and deallocates the audio buffer resources.
 */
- (void)cleanupAudioBuffer;

/**
 * @brief Cleans up system tap resources in a safe, ordered manner.
 * @param tapDescription Optional tap description object to release (can be nil)
 */
- (void)cleanupSystemTapContext:(nullable id)tapDescription;

/**
 * @brief Initializes the system tap context with specified audio parameters.
 * @param sampleRate Target sample rate in Hz
 * @param frameSize Number of frames per buffer
 * @param channels Number of audio channels
 * @return 0 on success, -1 on failure
 */
- (int)initializeSystemTapContext:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;

/**
 * @brief Creates a Core Audio tap description for system audio capture.
 * @param channels Number of audio channels to configure the tap for
 * @return CATapDescription object on success, nil on failure
 */
- (nullable CATapDescription *)createSystemTapDescriptionForChannels:(UInt8)channels;

/**
 * @brief Creates an aggregate device with the specified tap description and audio parameters.
 * @param tapDescription Core Audio tap description for system audio capture
 * @param sampleRate Target sample rate in Hz
 * @param frameSize Number of frames per buffer
 * @return OSStatus indicating success (noErr) or error code
 */
- (OSStatus)createAggregateDeviceWithTapDescription:(CATapDescription *)tapDescription sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize;

@end

NS_ASSUME_NONNULL_END
