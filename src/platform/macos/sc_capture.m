/**
 * @file src/platform/macos/sc_capture.m
 * @brief ScreenCaptureKit video capture for macOS virtual displays.
 */

// local includes
#import "sc_capture.h"

static char video_queue_key;

/**
 * @brief Private ScreenCaptureKit capture state and synchronization properties.
 */
API_AVAILABLE(macos(12.3))
@interface SCCapture ()

/** @brief CoreGraphics display identifier selected for capture. */
@property (nonatomic, assign) CGDirectDisplayID displayID;
/** @brief Requested capture frame rate. */
@property (nonatomic, assign) int frameRate;
/** @brief Active ScreenCaptureKit stream. */
@property (nonatomic, strong) SCStream *stream;
/** @brief Serial queue that delivers video frames. */
@property (nonatomic, strong) dispatch_queue_t videoQueue;
/** @brief Callback invoked for valid video frames. */
@property (nonatomic, copy) SCVideoFrameCallbackBlock frameCallback;
/** @brief Semaphore signaled when capture stops. */
@property (nonatomic, strong) dispatch_semaphore_t captureSignal;
/** @brief Whether capture shutdown has begun. */
@property (nonatomic, assign) BOOL stopping;
/** @brief Whether asynchronous capture setup is in progress. */
@property (nonatomic, assign) BOOL starting;
/** @brief Whether the active stream stopped because of a capture error. */
@property (nonatomic, readwrite) BOOL captureFailed;

@end

API_AVAILABLE(macos(12.3))
@implementation SCCapture

- (instancetype)initWithDisplay:(CGDirectDisplayID)display_id frameRate:(int)frame_rate {
  self = [super init];
  if (!self) {
    return nil;
  }

  self.displayID = display_id;
  self.frameRate = frame_rate;
  self.pixelFormat = kCVPixelFormatType_32BGRA;

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display_id);
  if (mode) {
    self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
    self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
    CGDisplayModeRelease(mode);
  } else {
    self.frameWidth = (int) CGDisplayPixelsWide(display_id);
    self.frameHeight = (int) CGDisplayPixelsHigh(display_id);
  }
  if (self.frameWidth <= 0 || self.frameHeight <= 0) {
    return nil;
  }

  dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
    DISPATCH_QUEUE_SERIAL,
    QOS_CLASS_USER_INITIATED,
    DISPATCH_QUEUE_PRIORITY_HIGH
  );
  self.videoQueue = dispatch_queue_create("dev.lizardbyte.sunshine.virtual-display-capture", attributes);
  dispatch_queue_set_specific(self.videoQueue, &video_queue_key, (__bridge void *) self, NULL);
  return self;
}

- (void)dealloc {
  [self stopCapture];
}

- (void)setFrameWidth:(int)frame_width frameHeight:(int)frame_height {
  self.frameWidth = frame_width;
  self.frameHeight = frame_height;
}

/**
 * @brief Refresh shareable content until the selected display becomes visible.
 *
 * @return Matching ScreenCaptureKit display, or `nil` after bounded retries.
 */
- (SCDisplay *)findDisplay {
  static const int attempts = 3;
  for (int attempt = 0; attempt < attempts; ++attempt) {
    if (attempt > 0) {
      [NSThread sleepForTimeInterval:0.25];
    }

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block SCShareableContent *shareable_content = nil;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      if (error) {
        NSLog(@"[SCCapture] Could not enumerate shareable content: %@", error.localizedDescription);
      } else {
        shareable_content = content;
      }
      dispatch_semaphore_signal(ready);
    }];

    const long wait_result = dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 750LL * NSEC_PER_MSEC));
    if (wait_result != 0 || !shareable_content) {
      continue;
    }

    for (SCDisplay *display in shareable_content.displays) {
      if (display.displayID == self.displayID) {
        return display;
      }
    }
  }

  return nil;
}

- (dispatch_semaphore_t)capture:(SCVideoFrameCallbackBlock)frame_callback {
  @synchronized(self) {
    if (self.stream || self.starting) {
      return nil;
    }
    self.starting = YES;
    self.stopping = NO;
    self.captureFailed = NO;
  }

  SCDisplay *display = [self findDisplay];
  if (!display) {
    NSLog(@"[SCCapture] Display %u did not appear in shareable content", self.displayID);
    @synchronized(self) {
      self.starting = NO;
    }
    return nil;
  }

  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
  configuration.width = self.frameWidth;
  configuration.height = self.frameHeight;
  configuration.minimumFrameInterval = CMTimeMake(1, self.frameRate);
  configuration.pixelFormat = self.pixelFormat;
  configuration.queueDepth = 5;
  configuration.showsCursor = YES;

  NSError *error = nil;
  SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
  if (!stream || ![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.videoQueue error:&error]) {
    NSLog(@"[SCCapture] Could not configure video output: %@", error.localizedDescription);
    @synchronized(self) {
      self.starting = NO;
      self.captureFailed = YES;
    }
    return nil;
  }

  dispatch_semaphore_t capture_signal = dispatch_semaphore_create(0);
  dispatch_semaphore_t started = dispatch_semaphore_create(0);
  __block BOOL start_succeeded = NO;
  @synchronized(self) {
    if (self.stopping) {
      self.starting = NO;
      return nil;
    }
    self.stream = stream;
    self.frameCallback = frame_callback;
    self.captureSignal = capture_signal;
    [stream startCaptureWithCompletionHandler:^(NSError *start_error) {
      if (start_error) {
        NSLog(@"[SCCapture] Could not start capture: %@", start_error.localizedDescription);
      } else {
        start_succeeded = YES;
      }
      dispatch_semaphore_signal(started);
    }];
  }

  if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 2LL * NSEC_PER_SEC)) != 0 || !start_succeeded) {
    @synchronized(self) {
      self.starting = NO;
      self.captureFailed = YES;
    }
    [self stopCapture];
    return nil;
  }

  @synchronized(self) {
    self.starting = NO;
    if (self.stopping || self.stream != stream || self.captureSignal != capture_signal) {
      return nil;
    }
    return capture_signal;
  }
}

- (void)stopCapture {
  SCStream *stream = nil;
  dispatch_semaphore_t capture_signal = nil;
  @synchronized(self) {
    self.stopping = YES;
    self.frameCallback = nil;
    stream = self.stream;
    self.stream = nil;
    capture_signal = self.captureSignal;
    self.captureSignal = nil;
  }

  if (stream) {
    dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        NSLog(@"[SCCapture] Error stopping capture: %@", error.localizedDescription);
      }
      dispatch_semaphore_signal(stopped);
    }];
    (void) dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 1500LL * NSEC_PER_MSEC));
  }

  if (self.videoQueue && dispatch_get_specific(&video_queue_key) != (__bridge void *) self) {
    dispatch_sync(self.videoQueue, ^ {});
  }
  if (capture_signal) {
    dispatch_semaphore_signal(capture_signal);
  }
}

- (BOOL)captureFailed {
  @synchronized(self) {
    return _captureFailed;
  }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  if (error) {
    NSLog(@"[SCCapture] Stream stopped with error: %@", error.localizedDescription);
  }
  @synchronized(self) {
    if (stream != self.stream) {
      return;
    }
    self.captureFailed = error != nil;
    if (self.captureSignal) {
      dispatch_semaphore_signal(self.captureSignal);
    }
  }
}

- (void)stream:(SCStream *)stream
  didOutputSampleBuffer:(CMSampleBufferRef)sample_buffer
                 ofType:(SCStreamOutputType)type {
  (void) stream;
  if (type != SCStreamOutputTypeScreen || !CMSampleBufferGetImageBuffer(sample_buffer)) {
    return;
  }

  NSArray *attachments = (__bridge NSArray *) CMSampleBufferGetSampleAttachmentsArray(sample_buffer, NO);
  NSNumber *frame_status = [attachments.firstObject objectForKey:SCStreamFrameInfoStatus];
  if (frame_status && frame_status.integerValue != SCFrameStatusComplete) {
    return;
  }

  SCVideoFrameCallbackBlock frame_callback = nil;
  @synchronized(self) {
    if (stream == self.stream && !self.stopping) {
      frame_callback = self.frameCallback;
    }
  }
  if (!frame_callback || frame_callback(sample_buffer)) {
    return;
  }

  @synchronized(self) {
    self.stopping = YES;
    if (self.captureSignal) {
      dispatch_semaphore_signal(self.captureSignal);
    }
  }
}

@end
