/**
 * @file src/platform/macos/sc_capture.h
 * @brief ScreenCaptureKit video capture for macOS virtual displays.
 */
#pragma once

// platform includes
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

/**
 * @brief Callback invoked for each ScreenCaptureKit video frame.
 *
 * @param sample_buffer Captured video sample buffer.
 * @return `true` to continue capture or `false` to stop it.
 */
typedef bool (^SCVideoFrameCallbackBlock)(CMSampleBufferRef sample_buffer);

/**
 * @brief ScreenCaptureKit video controller used for session-owned virtual displays.
 */
API_AVAILABLE(macos(12.3))
@interface SCCapture: NSObject <SCStreamDelegate, SCStreamOutput>

/** @brief Output pixel format requested from ScreenCaptureKit. */
@property (nonatomic, assign) OSType pixelFormat;
/** @brief Captured frame width in pixels. */
@property (nonatomic, assign) int frameWidth;
/** @brief Captured frame height in pixels. */
@property (nonatomic, assign) int frameHeight;
/** @brief Whether the active stream stopped because of a capture error. */
@property (nonatomic, readonly) BOOL captureFailed;

/**
 * @brief Initialize capture metadata for a display.
 *
 * @param display_id CoreGraphics display identifier.
 * @param frame_rate Requested capture frame rate.
 * @return Initialized controller, or `nil` when display geometry is invalid.
 */
- (instancetype)initWithDisplay:(CGDirectDisplayID)display_id frameRate:(int)frame_rate;

/**
 * @brief Override the output frame dimensions used by the encoder.
 *
 * @param frame_width Frame width in pixels.
 * @param frame_height Frame height in pixels.
 */
- (void)setFrameWidth:(int)frame_width frameHeight:(int)frame_height;

/**
 * @brief Start ScreenCaptureKit video capture.
 *
 * @param frame_callback Callback invoked for each valid video frame.
 * @return Semaphore signaled when capture stops, or `nil` on setup failure.
 */
- (dispatch_semaphore_t)capture:(SCVideoFrameCallbackBlock)frame_callback;

/**
 * @brief Stop capture, drain its callback queue, and wake the waiting worker.
 */
- (void)stopCapture;

@end
