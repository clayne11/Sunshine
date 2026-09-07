/**
 * @file src/platform/macos/vd_helper.m
 * @brief Helper process to create and hold a CGVirtualDisplay.
 *
 * Spawned by Sunshine to create virtual displays in a clean process context.
 * Usage: @code vd_helper width height fps [extend|exclusive] @endcode
 * Outputs: displayID on stdout (or "0" on failure)
 * Stays alive holding the display until SIGTERM is received.
 *
 * CGVirtualDisplay creates the display object, then we:
 *   1. SLSConfigureDisplayEnabled activates it in WindowServer's display list
 *   2. CGConfigureDisplayMirrorOfDisplay(kCGNullDirectDisplay) forces extend mode
 *      (macOS may auto-mirror new displays, hiding them from CGGetActiveDisplayList)
 * Compiled with ARC (-fobjc-arc).
 */
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/** @brief A mode exposed by the private CGVirtualDisplay API. */
@interface CGVirtualDisplayMode: NSObject
/**
 * @brief Initialize a virtual-display mode.
 * @param width Logical mode width in pixels.
 * @param height Logical mode height in pixels.
 * @param refreshRate Mode refresh rate in hertz.
 * @return The initialized mode.
 */
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

/** @brief Settings applied to a private CGVirtualDisplay. */
@interface CGVirtualDisplaySettings: NSObject
/** @brief Whether the virtual display uses high-DPI modes. */
@property (nonatomic) unsigned int hiDPI;
/** @brief Modes offered by the virtual display. */
@property (retain, nonatomic) NSArray *modes;
@end

/** @brief Descriptor used to create a private CGVirtualDisplay. */
@interface CGVirtualDisplayDescriptor: NSObject
/** @brief Human-readable display name. */
@property (retain, nonatomic) NSString *name;
/** @brief Display vendor identifier. */
@property (nonatomic) unsigned int vendorID;
/** @brief Display product identifier. */
@property (nonatomic) unsigned int productID;
/** @brief Display serial number. */
@property (nonatomic) unsigned int serialNum;
/** @brief Maximum pixel width. */
@property (nonatomic) unsigned int maxPixelsWide;
/** @brief Maximum pixel height. */
@property (nonatomic) unsigned int maxPixelsHigh;
/** @brief Physical display size in millimeters. */
@property (nonatomic) CGSize sizeInMillimeters;
/** @brief Display white point. */
@property (nonatomic) CGPoint whitePoint;
/** @brief Display red primary chromaticity. */
@property (nonatomic) CGPoint redPrimary;
/** @brief Display green primary chromaticity. */
@property (nonatomic) CGPoint greenPrimary;
/** @brief Display blue primary chromaticity. */
@property (nonatomic) CGPoint bluePrimary;
/** @brief Queue used for virtual-display callbacks. */
@property (retain, nonatomic) dispatch_queue_t queue;
/** @brief Callback invoked when WindowServer terminates the display. */
@property (copy, nonatomic) void (^terminationHandler)(id, id);
/**
 * @brief Set the queue used for virtual-display callbacks.
 * @param queue Callback dispatch queue.
 */
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

/** @brief Private CoreGraphics virtual display object. */
@interface CGVirtualDisplay: NSObject
/** @brief WindowServer display identifier. */
@property (readonly, nonatomic) unsigned int displayID;
/**
 * @brief Initialize a virtual display from a descriptor.
 * @param descriptor Display descriptor.
 * @return The initialized display, or nil on failure.
 */
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
/**
 * @brief Apply display modes and scaling settings.
 * @param settings Display settings.
 * @return YES when WindowServer accepts the settings.
 */
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// SkyLight private C functions for display configuration (linked directly).
/**
 * @brief Begin a private display configuration transaction.
 * @param config Receives the configuration reference.
 * @return CoreGraphics error code.
 */
extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *config);
/**
 * @brief Set display enablement within a configuration transaction.
 * @param config Configuration reference.
 * @param displayID Display identifier.
 * @param enabled Whether to enable the display.
 * @return CoreGraphics error code.
 */
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID displayID, bool enabled);
/**
 * @brief Set display origin within a configuration transaction.
 * @param config Configuration reference.
 * @param displayID Display identifier.
 * @param x Horizontal origin.
 * @param y Vertical origin.
 * @return CoreGraphics error code.
 */
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef config, CGDirectDisplayID displayID, int32_t x, int32_t y);
/**
 * @brief Complete a private display configuration transaction.
 * @param config Configuration reference.
 * @param option Configuration scope.
 * @param flags Completion flags.
 * @return CoreGraphics error code.
 */
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef config, CGConfigureOption option, uint32_t flags);

// Static storage to keep objects alive (ARC retains static references).
static CGVirtualDisplay *keepAlive = nil;
static CGVirtualDisplayDescriptor *keepDesc = nil;

static volatile sig_atomic_t shouldExit = 0;  ///< Set by the async-safe signal handler.
static pid_t originalParentPID = 0;  ///< Sunshine's PID captured before setup.
static CGDirectDisplayID originalDisplayIDs[64];  ///< Displays active before creation.
static uint32_t originalDisplayCount = 0;  ///< Number of saved display IDs.
static CGDirectDisplayID originalOnlineDisplayIDs[64];  ///< All physical displays online before creation.
static uint32_t originalOnlineDisplayCount = 0;  ///< Number of saved online display IDs.
static BOOL exclusiveApplied = NO;  ///< Whether physical displays were disabled.

/**
 * @brief Request orderly helper shutdown from an async signal context.
 * @param sig Signal number, intentionally unused.
 */
static void handle_signal(int sig) {
  (void) sig;
  shouldExit = 1;
}

/**
 * @brief Check whether the Sunshine process that launched this helper remains alive.
 * @return YES while the original parent process still owns the helper.
 */
static BOOL parentIsAlive(void) {
  return originalParentPID > 1 && getppid() == originalParentPID;
}

/**
 * @brief Install persistent signal handlers for orderly display cleanup.
 * @return YES when all requested handlers were installed.
 */
static BOOL installSignalHandlers(void) {
  struct sigaction action = {};
  action.sa_handler = handle_signal;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;
  return sigaction(SIGTERM, &action, NULL) == 0 && sigaction(SIGINT, &action, NULL) == 0 &&
         sigaction(SIGHUP, &action, NULL) == 0;
}

/**
 * @brief Check whether a display ID is in the active display list.
 * @param targetID Display identifier to find.
 * @param outCount Optional output for the number of active displays.
 * @return YES when targetID is active.
 */
static BOOL checkDisplayInList(uint32_t targetID, uint32_t *outCount) {
  CGDirectDisplayID activeDisplays[32];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(32, activeDisplays, &displayCount) == kCGErrorSuccess) {
    if (outCount) {
      *outCount = displayCount;
    }
    for (uint32_t i = 0; i < displayCount; i++) {
      if (activeDisplays[i] == targetID) {
        return YES;
      }
    }
  }
  return NO;
}

/**
 * @brief Wait for WindowServer to expose an online, active display.
 * @param displayID Display identifier to inspect.
 * @return YES when the display is ready before the bounded deadline.
 */
static BOOL waitForDisplayReady(CGDirectDisplayID displayID) {
  static const unsigned int attempts = 40;
  static const useconds_t interval = 50000;
  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    if (shouldExit || !parentIsAlive()) {
      return NO;
    }
    if (CGDisplayIsOnline(displayID) && CGDisplayIsActive(displayID)) {
      return YES;
    }
    usleep(interval);
  }
  return !shouldExit && parentIsAlive() && CGDisplayIsOnline(displayID) && CGDisplayIsActive(displayID);
}

/**
 * @brief Save the active and online displays before creating the virtual display.
 * @return YES when WindowServer returned usable snapshots.
 */
static BOOL captureOriginalDisplays(void) {
  originalDisplayCount = 0;
  originalOnlineDisplayCount = 0;
  CGError error = CGGetActiveDisplayList(64, originalDisplayIDs, &originalDisplayCount);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not snapshot active displays: %d\n", error);
    originalDisplayCount = 0;
    return NO;
  }
  error = CGGetOnlineDisplayList(64, originalOnlineDisplayIDs, &originalOnlineDisplayCount);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not snapshot online displays: %d\n", error);
    originalDisplayCount = 0;
    originalOnlineDisplayCount = 0;
    return NO;
  }
  return YES;
}

/**
 * @brief Check that the virtual display is the only active display.
 * @param virtualID Virtual display identifier.
 * @return YES when the active display list contains only virtualID.
 */
static BOOL onlyVirtualDisplayActive(CGDirectDisplayID virtualID) {
  CGDirectDisplayID activeDisplays[64];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(64, activeDisplays, &displayCount) != kCGErrorSuccess || displayCount != 1) {
    return NO;
  }
  return activeDisplays[0] == virtualID;
}

/**
 * @brief Test whether a display ID occurs in a saved display list.
 * @param displays Display ID array.
 * @param displayCount Number of IDs in displays.
 * @param targetID Display ID to find.
 * @return YES when targetID occurs in the list.
 */
static BOOL displayIDIsInList(const CGDirectDisplayID *displays, uint32_t displayCount, CGDirectDisplayID targetID) {
  for (uint32_t index = 0; index < displayCount; ++index) {
    if (displays[index] == targetID) {
      return YES;
    }
  }
  return NO;
}

/**
 * @brief Check that the active display list has returned to the saved snapshot.
 * @param virtualID Virtual display identifier to exclude from the snapshot.
 * @return YES when every saved display is active and the virtual display is absent.
 */
static BOOL originalDisplaysAreActive(CGDirectDisplayID virtualID) {
  CGDirectDisplayID activeDisplays[64];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(64, activeDisplays, &displayCount) != kCGErrorSuccess ||
      displayCount != originalDisplayCount) {
    return NO;
  }

  for (uint32_t originalIndex = 0; originalIndex < originalDisplayCount; ++originalIndex) {
    if (!displayIDIsInList(activeDisplays, displayCount, originalDisplayIDs[originalIndex]) ||
        originalDisplayIDs[originalIndex] == virtualID) {
      return NO;
    }
  }
  return YES;
}

/**
 * @brief Wait for the saved physical display arrangement to become active.
 * @param virtualID Virtual display identifier to exclude from the snapshot.
 * @return YES when the saved arrangement is restored before the deadline.
 */
static BOOL waitForOriginalDisplays(CGDirectDisplayID virtualID) {
  static const unsigned int attempts = 40;
  static const useconds_t interval = 50000;
  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    if (originalDisplaysAreActive(virtualID)) {
      return YES;
    }
    usleep(interval);
  }
  return originalDisplaysAreActive(virtualID);
}

/**
 * @brief Restore the pre-session display enablement and disable the virtual display.
 * @param virtualID Virtual display identifier.
 * @return YES when the app-only restoration completed successfully.
 */
static BOOL restoreOriginalDisplays(CGDirectDisplayID virtualID) {
  CGDisplayConfigRef config = NULL;
  CGError error = SLSBeginDisplayConfiguration(&config);
  if (error != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] Could not begin display restoration: %d\n", error);
    return NO;
  }

  for (uint32_t i = 0; i < originalOnlineDisplayCount; ++i) {
    const CGDirectDisplayID displayID = originalOnlineDisplayIDs[i];
    if (displayID == virtualID) {
      continue;
    }
    const bool wasActive = displayIDIsInList(originalDisplayIDs, originalDisplayCount, displayID);
    error = SLSConfigureDisplayEnabled(config, displayID, wasActive);
    if (error != kCGErrorSuccess) {
      fprintf(stderr, "[vd_helper] Could not restore display %u: %d\n", displayID, error);
      CGCancelDisplayConfiguration(config);
      return NO;
    }
  }

  // An active display should normally also be online, but preserve any unusual
  // WindowServer state by restoring active IDs that were absent from the online snapshot.
  for (uint32_t i = 0; i < originalDisplayCount; ++i) {
    const CGDirectDisplayID displayID = originalDisplayIDs[i];
    if (displayID == virtualID || displayIDIsInList(originalOnlineDisplayIDs, originalOnlineDisplayCount, displayID)) {
      continue;
    }
    error = SLSConfigureDisplayEnabled(config, displayID, true);
    if (error != kCGErrorSuccess) {
      fprintf(stderr, "[vd_helper] Could not restore display %u: %d\n", displayID, error);
      CGCancelDisplayConfiguration(config);
      return NO;
    }
  }

  if (virtualID != 0 && CGDisplayIsOnline(virtualID)) {
    error = SLSConfigureDisplayEnabled(config, virtualID, false);
    if (error != kCGErrorSuccess) {
      fprintf(stderr, "[vd_helper] Could not disable virtual display %u: %d\n", virtualID, error);
      CGCancelDisplayConfiguration(config);
      return NO;
    }
  }

  error = SLSCompleteDisplayConfiguration(config, kCGConfigureForAppOnly, 0);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not complete display restoration: %d\n", error);
    CGCancelDisplayConfiguration(config);
    return NO;
  }
  if (!waitForOriginalDisplays(virtualID)) {
    fprintf(stderr, "[vd_helper] Restored display configuration did not match the saved snapshot\n");
    return NO;
  }
  return YES;
}

/**
 * @brief Temporarily disable the original displays after the virtual display is ready.
 * @param virtualID Virtual display identifier.
 * @return YES when the virtual display is the only active display.
 */
static BOOL applyExclusiveMode(CGDirectDisplayID virtualID) {
  if (!waitForDisplayReady(virtualID)) {
    fprintf(stderr, "[vd_helper] Virtual display %u is not ready; keeping physical displays enabled\n", virtualID);
    return NO;
  }

  CGDisplayConfigRef config = NULL;
  CGError error = SLSBeginDisplayConfiguration(&config);
  if (error != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] Could not begin exclusive display configuration: %d\n", error);
    return NO;
  }

  error = SLSConfigureDisplayEnabled(config, virtualID, true);
  for (uint32_t i = 0; error == kCGErrorSuccess && i < originalOnlineDisplayCount; ++i) {
    if (originalOnlineDisplayIDs[i] == virtualID) {
      continue;
    }
    error = SLSConfigureDisplayEnabled(config, originalOnlineDisplayIDs[i], false);
  }

  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not prepare exclusive display configuration: %d\n", error);
    CGCancelDisplayConfiguration(config);
    return NO;
  }

  error = SLSCompleteDisplayConfiguration(config, kCGConfigureForAppOnly, 0);
  if (error != kCGErrorSuccess || !waitForDisplayReady(virtualID) || !onlyVirtualDisplayActive(virtualID)) {
    fprintf(stderr, "[vd_helper] Exclusive configuration did not leave only virtual display active\n");
    if (error != kCGErrorSuccess) {
      CGCancelDisplayConfiguration(config);
    }
    if (!restoreOriginalDisplays(virtualID)) {
      fprintf(stderr, "[vd_helper] Display restoration after exclusive failure also failed\n");
    }
    return NO;
  }

  exclusiveApplied = YES;
  return YES;
}

/**
 * @brief Enable the virtual display and place it beside the main display.
 * @param virtualID Virtual display identifier.
 * @param exclusive Whether the configuration should remain app-local.
 * @return YES when WindowServer accepted the configuration.
 */
static BOOL activateVirtualDisplay(CGDirectDisplayID virtualID, BOOL exclusive) {
  CGDisplayConfigRef config = NULL;
  CGError error = SLSBeginDisplayConfiguration(&config);
  if (error != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] Could not begin virtual display configuration: %d\n", error);
    return NO;
  }

  error = SLSConfigureDisplayEnabled(config, virtualID, true);
  if (error == kCGErrorSuccess) {
    const CGDirectDisplayID mainDisplay = CGMainDisplayID();
    const int32_t mainWidth = (int32_t) CGDisplayPixelsWide(mainDisplay);
    error = SLSConfigureDisplayOrigin(config, virtualID, mainWidth, 0);
  }
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not prepare virtual display %u: %d\n", virtualID, error);
    CGCancelDisplayConfiguration(config);
    return NO;
  }

  const CGConfigureOption option = exclusive ? kCGConfigureForAppOnly : kCGConfigureForSession;
  error = SLSCompleteDisplayConfiguration(config, option, 0);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not activate virtual display %u: %d\n", virtualID, error);
    CGCancelDisplayConfiguration(config);
    return NO;
  }
  return YES;
}

/**
 * @brief Force the virtual display into extend mode instead of mirroring.
 *
 * macOS may auto-mirror new displays, which hides them from the active display
 * list. This un-mirrors the display and positions it to the right of the main
 * display.
 *
 * @param virtualID Virtual display identifier.
 */
static void forceExtendMode(CGDirectDisplayID virtualID) {
  CGDirectDisplayID mainDisplay = CGMainDisplayID();

  // Check if main display is now mirroring our virtual display
  CGDirectDisplayID mainMirrorTarget = CGDisplayMirrorsDisplay(mainDisplay);
  if (mainMirrorTarget == virtualID) {
    fprintf(stderr, "[vd_helper] Main display is mirroring us (%u), un-mirroring main\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, mainDisplay, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // Check if our display is in a mirror set
  if (CGDisplayIsInMirrorSet(virtualID)) {
    fprintf(stderr, "[vd_helper] Display %u is in mirror set, un-mirroring\n", virtualID);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // Also check if virtual display is mirroring main
  CGDirectDisplayID virtualMirrorTarget = CGDisplayMirrorsDisplay(virtualID);
  if (virtualMirrorTarget != 0) {
    fprintf(stderr, "[vd_helper] Display %u mirrors %u, un-mirroring\n", virtualID, virtualMirrorTarget);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayMirrorOfDisplay(config, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // Position it to the right of main display
  {
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      size_t mainWidth = CGDisplayPixelsWide(mainDisplay);
      CGConfigureDisplayOrigin(config, virtualID, (int32_t) mainWidth, 0);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // If the virtual display became the main display, restore the original
  CGDirectDisplayID newMain = CGMainDisplayID();
  if (newMain == virtualID && newMain != mainDisplay) {
    fprintf(stderr, "[vd_helper] Virtual display became main, restoring original main %u\n", mainDisplay);
    CGDisplayConfigRef config = NULL;
    CGBeginDisplayConfiguration(&config);
    if (config) {
      CGConfigureDisplayOrigin(config, mainDisplay, 0, 0);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }
}

/**
 * @brief Create and hold a virtual display until shutdown is requested.
 * @param argc Argument count.
 * @param argv Width, height, refresh rate, and optional display mode.
 * @return Zero after orderly cleanup, otherwise a startup error code.
 */
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    // vd_helper owns the CGVirtualDisplay object. If Sunshine exits without
    // calling virtual_display_destroy(), launchd reparents this process and
    // the display would otherwise remain registered indefinitely.
    originalParentPID = getppid();

    if (!parentIsAlive()) {
      fprintf(stderr, "[vd_helper] No live Sunshine parent process found\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (argc != 4 && argc != 5) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    BOOL exclusiveMode = NO;
    if (argc == 5) {
      if (strcmp(argv[4], "exclusive") == 0) {
        exclusiveMode = YES;
      } else if (strcmp(argv[4], "extend") != 0) {
        fprintf(stderr, "[vd_helper] Unknown display mode: %s\n", argv[4]);
        fprintf(stdout, "0\n");
        fflush(stdout);
        return 1;
      }
    }

    int width = atoi(argv[1]);
    int height = atoi(argv[2]);
    int fps = atoi(argv[3]);

    if (width <= 0 || height <= 0 || fps <= 0) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (!installSignalHandlers()) {
      fprintf(stderr, "[vd_helper] Could not install signal handlers: %s\n", strerror(errno));
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (exclusiveMode && !captureOriginalDisplays()) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Runtime availability check
    if (!NSClassFromString(@"CGVirtualDisplay")) {
      fprintf(stderr, "[vd_helper] CGVirtualDisplay API not available\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Initialize NSApplication
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    // Create display directly on main thread
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = @"Sunshine Virtual Display";
    desc.vendorID = 0xF0F0;
    desc.productID = 0x5678;
    desc.serialNum = arc4random();
    desc.maxPixelsWide = (unsigned int) width;
    desc.maxPixelsHigh = (unsigned int) height;
    // Fixed 27" monitor physical size — do NOT scale linearly with resolution.
    // WindowServer rejects displays with unreasonably large physical dimensions.
    desc.sizeInMillimeters = CGSizeMake(597, 336);
    desc.whitePoint = CGPointMake(0.3127, 0.3290);
    desc.redPrimary = CGPointMake(0.64, 0.33);
    desc.greenPrimary = CGPointMake(0.30, 0.60);
    desc.bluePrimary = CGPointMake(0.15, 0.06);
    [desc setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    desc.terminationHandler = ^(id s, id d) {
      (void) s;
      (void) d;
      fprintf(stderr, "[vd_helper] Virtual display terminated by system\n");
      shouldExit = 1;
    };

    CGVirtualDisplayMode *nativeMode = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int) width
                                                                            height:(unsigned int) height
                                                                       refreshRate:(double) fps];
    if (!nativeMode) {
      fprintf(stderr, "[vd_helper] Failed to create CGVirtualDisplayMode\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Build mode list with native + half-resolution mode.
    // With hiDPI=1, macOS selects the native mode as the retina backing store
    // and the half-res mode as the logical resolution (2x scaling).
    // Without this, macOS only gives us half the requested pixel resolution.
    CGVirtualDisplayMode *halfMode = nil;
    if (width >= 2 && height >= 2) {
      halfMode = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int) (width / 2)
                                                      height:(unsigned int) (height / 2)
                                                 refreshRate:(double) fps];
    }
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    if (halfMode) {
      settings.modes = @[nativeMode, halfMode];
    } else {
      settings.modes = @[nativeMode];
    }

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    __block BOOL settingsApplied = NO;
    if (!display) {
      fprintf(stderr, "[vd_helper] initWithDescriptor returned nil (trying background thread)\n");

      // Fallback: try on background thread
      __block CGVirtualDisplay *bgDisplay = nil;
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        bgDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (bgDisplay) {
          settingsApplied = [bgDisplay applySettings:settings];
        }
        dispatch_semaphore_signal(sem);
      });
      if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "[vd_helper] Timed out creating virtual display on background thread\n");
        keepAlive = nil;
        keepDesc = nil;
        fprintf(stdout, "0\n");
        fflush(stdout);
        return 1;
      }
      display = bgDisplay;
    } else {
      settingsApplied = [display applySettings:settings];
    }

    if (!display || !settingsApplied || display.displayID == 0) {
      fprintf(stderr, "[vd_helper] Failed to create virtual display\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    keepAlive = display;
    keepDesc = desc;
    uint32_t resultID = display.displayID;

    fprintf(stderr, "[vd_helper] Display %u created, activating...\n", resultID);

    if (!parentIsAlive() || shouldExit || !activateVirtualDisplay(resultID, exclusiveMode)) {
      fprintf(stderr, "[vd_helper] Virtual display activation failed\n");
      if (exclusiveMode) {
        restoreOriginalDisplays(resultID);
      }
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Wait for WindowServer to process the display
    usleep(500000);  // 500ms

    if (!parentIsAlive() || shouldExit) {
      fprintf(stderr, "[vd_helper] Parent exited while activating virtual display\n");
      if (exclusiveMode) {
        restoreOriginalDisplays(resultID);
      }
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Step 2: Force extend mode (un-mirror) if needed
    if (CGDisplayIsInMirrorSet(resultID) || CGDisplayMirrorsDisplay(resultID) != 0) {
      fprintf(stderr, "[vd_helper] Mirror detected, forcing extend mode\n");
      forceExtendMode(resultID);
    }

    // Step 3: Switch to native resolution (1x scale) mode.
    // The display starts as retina 2x (logical=half, pixel=full).
    // For streaming, we want native 1x (logical=full, pixel=full) to avoid
    // compositor overhead that causes latency and FPS drops.
    {
      NSDictionary *opts = @{(NSString *) kCGDisplayShowDuplicateLowResolutionModes: @YES};
      CFArrayRef allModes = CGDisplayCopyAllDisplayModes(resultID, (CFDictionaryRef) opts);
      if (allModes) {
        CGDisplayModeRef nativeMode = NULL;
        CFIndex modeCount = CFArrayGetCount(allModes);
        for (CFIndex i = 0; i < modeCount; i++) {
          CGDisplayModeRef m = (CGDisplayModeRef) CFArrayGetValueAtIndex(allModes, i);
          size_t lw = CGDisplayModeGetWidth(m);
          size_t lh = CGDisplayModeGetHeight(m);
          size_t pw = CGDisplayModeGetPixelWidth(m);
          size_t ph = CGDisplayModeGetPixelHeight(m);
          // Find the 1x native mode matching our requested resolution
          if ((int) lw == width && (int) lh == height && pw == lw && ph == lh) {
            nativeMode = m;
            break;
          }
        }
        if (nativeMode) {
          CGError modeErr = CGDisplaySetDisplayMode(resultID, nativeMode, NULL);
          fprintf(stderr, "[vd_helper] Switched to native %dx%d (1x scale): %d\n", width, height, modeErr);
        } else {
          fprintf(stderr, "[vd_helper] Native %dx%d mode not found, staying at retina 2x\n", width, height);
        }
        CFRelease(allModes);
      }
    }

    // Wait for mode switch to take effect
    usleep(500000);  // 500ms

    // Step 3: If still not visible, try again after a longer wait
    uint32_t count = 0;
    BOOL found = checkDisplayInList(resultID, &count);
    if (!found) {
      fprintf(stderr, "[vd_helper] Display %u not found after first attempt, retrying...\n", resultID);
      sleep(1);
      // Check mirror state again
      fprintf(stderr, "[vd_helper] Mirror state (retry): inMirrorSet=%d, mirrorsDisplay=%u\n", CGDisplayIsInMirrorSet(resultID), CGDisplayMirrorsDisplay(resultID));
      forceExtendMode(resultID);
      usleep(500000);
      found = checkDisplayInList(resultID, &count);
    }

    fprintf(stderr, "[vd_helper] Display %u (%dx%d@%dHz) - %s in active list (%u total)\n", resultID, width, height, fps, found ? "FOUND" : "NOT found", count);

    if (!waitForDisplayReady(resultID)) {
      fprintf(stderr, "[vd_helper] Display %u did not become online and active\n", resultID);
      if (exclusiveMode) {
        restoreOriginalDisplays(resultID);
      }
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (exclusiveMode && !applyExclusiveMode(resultID)) {
      fprintf(stderr, "[vd_helper] Could not enter exclusive display mode\n");
      restoreOriginalDisplays(resultID);
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (!parentIsAlive() || shouldExit) {
      fprintf(stderr, "[vd_helper] Parent exited before virtual display became ready\n");
      if (exclusiveMode) {
        restoreOriginalDisplays(resultID);
      }
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    // Log all active displays for debugging
    {
      CGDirectDisplayID activeDisplays[32];
      uint32_t dCount = 0;
      CGGetActiveDisplayList(32, activeDisplays, &dCount);
      for (uint32_t i = 0; i < dCount; i++) {
        fprintf(stderr, "[vd_helper]   active[%u] = %u (online=%d, active=%d, mirror=%u)\n", i, activeDisplays[i], CGDisplayIsOnline(activeDisplays[i]), CGDisplayIsActive(activeDisplays[i]), CGDisplayMirrorsDisplay(activeDisplays[i]));
      }
      // Also check our display specifically
      fprintf(stderr, "[vd_helper]   ours[%u]: online=%d, active=%d, inMirror=%d, mirrors=%u\n", resultID, CGDisplayIsOnline(resultID), CGDisplayIsActive(resultID), CGDisplayIsInMirrorSet(resultID), CGDisplayMirrorsDisplay(resultID));
    }

    fprintf(stdout, "%u\n", resultID);
    fflush(stdout);

    // Keep alive via CFRunLoop
    while (!shouldExit) {
      if (!parentIsAlive()) {
        fprintf(stderr, "[vd_helper] Parent process %d exited; shutting down\n", originalParentPID);
        shouldExit = 1;
        break;
      }
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }

    if (exclusiveApplied && !restoreOriginalDisplays(resultID)) {
      fprintf(stderr, "[vd_helper] Display restoration during shutdown failed\n");
    }
    fprintf(stderr, "[vd_helper] Shutting down, releasing display %u\n", resultID);
    keepAlive = nil;
    keepDesc = nil;
  }
  return 0;
}
