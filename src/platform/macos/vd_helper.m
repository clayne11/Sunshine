/**
 * @file src/platform/macos/vd_helper.m
 * @brief Helper process to create and hold a CGVirtualDisplay.
 *
 * Spawned by Sunshine to create virtual displays in a clean process context.
 * Usage: @code vd_helper width height fps [extend|exclusive] @endcode
 * Outputs: displayID on stdout (or "0" on failure)
 * Stays alive holding the display until SIGTERM is received.
 *
 * CGVirtualDisplay creates and registers the display object, then we:
 *   1. CGConfigureDisplayOrigin places it beside the main display
 *   2. CGConfigureDisplayMirrorOfDisplay(kCGNullDirectDisplay) forces extend mode
 *      (macOS may auto-mirror new displays, hiding them from CGGetActiveDisplayList)
 *   3. In exclusive mode, SLSConfigureDisplayEnabled disables the saved physical displays
 * Compiled with ARC (-fobjc-arc).
 */
#include "vd_spawn.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

/** @brief Process environment passed to the holder subprocess. */
extern char **environ;

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

// SkyLight private C functions for physical display enablement (linked directly).
/**
 * @brief Set physical display enablement within a configuration transaction.
 * @param config Configuration reference.
 * @param displayID Display identifier.
 * @param enabled Whether to enable the display.
 * @return CoreGraphics error code.
 */
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID displayID, bool enabled);

// Static storage to keep objects alive (ARC retains static references).
static CGVirtualDisplay *keepAlive = nil;
static CGVirtualDisplayDescriptor *keepDesc = nil;

static volatile sig_atomic_t shouldExit = 0;  ///< Set by the async-safe signal handler.
static pid_t originalParentPID = 0;  ///< Direct parent's PID captured before setup.
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
 * @brief Check whether the process that launched the current helper role remains alive.
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
 * @brief Check that physical active displays match the saved snapshot.
 * @param virtualID Virtual display identifier to ignore while it is still held by the helper.
 * @return YES when the active displays, excluding virtualID, exactly match the saved snapshot.
 */
static BOOL originalDisplaysAreActive(CGDirectDisplayID virtualID) {
  CGDirectDisplayID activeDisplays[64];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(64, activeDisplays, &displayCount) != kCGErrorSuccess) {
    return NO;
  }

  uint32_t remainingCount = 0;
  for (uint32_t activeIndex = 0; activeIndex < displayCount; ++activeIndex) {
    if (activeDisplays[activeIndex] == virtualID) {
      continue;
    }
    if (!displayIDIsInList(originalDisplayIDs, originalDisplayCount, activeDisplays[activeIndex])) {
      return NO;
    }
    ++remainingCount;
  }

  uint32_t savedPhysicalCount = 0;
  for (uint32_t originalIndex = 0; originalIndex < originalDisplayCount; ++originalIndex) {
    const CGDirectDisplayID displayID = originalDisplayIDs[originalIndex];
    if (displayID == virtualID) {
      continue;
    }
    ++savedPhysicalCount;
    if (!displayIDIsInList(activeDisplays, displayCount, displayID)) {
      return NO;
    }
  }
  return remainingCount == savedPhysicalCount;
}

/**
 * @brief Wait for the saved physical display arrangement to become active.
 * @param virtualID Virtual display identifier to exclude from the snapshot.
 * @return YES when the saved arrangement is restored before the deadline.
 */
static BOOL waitForOriginalDisplays(CGDirectDisplayID virtualID) {
  static const unsigned int attempts = 40;
  static const CFTimeInterval interval = 0.05;
  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    // CoreGraphics display notifications update process-local state through
    // the run loop. Pump it before inspecting the post-transaction layout.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, interval, false);
    if (originalDisplaysAreActive(virtualID)) {
      return YES;
    }
  }
  return originalDisplaysAreActive(virtualID);
}

/**
 * @brief Restore the pre-session physical display enablement.
 * @param virtualID Last virtual display identifier, ignored during physical-set validation.
 * @param option Lifetime for the completed restoration transaction.
 * @return YES when the restoration matches the saved physical display set.
 */
static BOOL restoreOriginalDisplays(CGDirectDisplayID virtualID, CGConfigureOption option) {
  CGDisplayConfigRef config = NULL;
  CGError error = CGBeginDisplayConfiguration(&config);
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

  error = CGCompleteDisplayConfiguration(config, option);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not complete display restoration: %d\n", error);
    return NO;
  }
  if (!waitForOriginalDisplays(virtualID)) {
    fprintf(stderr, "[vd_helper] Restored display configuration did not match the saved snapshot\n");
    return NO;
  }
  return YES;
}

/**
 * @brief Retry session-scoped physical recovery after a holder failure.
 * @param virtualID Last virtual display identifier reported by the holder.
 * @return YES when the saved physical display set was restored.
 */
static BOOL recoverOriginalDisplays(CGDirectDisplayID virtualID) {
  static const unsigned int attempts = 3;
  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    if (restoreOriginalDisplays(virtualID, kCGConfigureForSession)) {
      return YES;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
  }
  return NO;
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
  CGError error = CGBeginDisplayConfiguration(&config);
  if (error != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] Could not begin exclusive display configuration: %d\n", error);
    return NO;
  }

  error = kCGErrorSuccess;
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

  error = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
  if (error != kCGErrorSuccess || !waitForDisplayReady(virtualID) || !onlyVirtualDisplayActive(virtualID)) {
    fprintf(stderr, "[vd_helper] Exclusive configuration did not leave only virtual display active\n");
    if (!restoreOriginalDisplays(virtualID, kCGConfigureForAppOnly)) {
      fprintf(stderr, "[vd_helper] Display restoration after exclusive failure also failed\n");
    }
    return NO;
  }

  exclusiveApplied = YES;
  return YES;
}

/**
 * @brief Place the virtual display beside the main display.
 * @param virtualID Virtual display identifier.
 * @param exclusive Whether completion should remain app-local instead of session-wide.
 * @return YES when WindowServer accepted the configuration.
 */
static BOOL activateVirtualDisplay(CGDirectDisplayID virtualID, BOOL exclusive) {
  CGDisplayConfigRef config = NULL;
  CGError error = CGBeginDisplayConfiguration(&config);
  if (error != kCGErrorSuccess || !config) {
    fprintf(stderr, "[vd_helper] Could not begin virtual display configuration: %d\n", error);
    return NO;
  }

  const CGDirectDisplayID mainDisplay = CGMainDisplayID();
  const int32_t mainWidth = (int32_t) CGDisplayPixelsWide(mainDisplay);
  error = CGConfigureDisplayOrigin(config, virtualID, mainWidth, 0);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not prepare virtual display %u: %d\n", virtualID, error);
    CGCancelDisplayConfiguration(config);
    return NO;
  }

  const CGConfigureOption option = exclusive ? kCGConfigureForAppOnly : kCGConfigureForSession;
  error = CGCompleteDisplayConfiguration(config, option);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not activate virtual display %u: %d\n", virtualID, error);
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
 * @brief Parse and validate the display request shared by guardian and holder.
 * @param argc Argument count in the public helper layout.
 * @param argv Executable name followed by width, height, refresh rate, and optional mode.
 * @param width Receives the requested width.
 * @param height Receives the requested height.
 * @param fps Receives the requested refresh rate.
 * @param exclusive Receives whether exclusive mode was requested.
 * @return YES when every argument is valid.
 */
static BOOL parseDisplayArguments(int argc, const char *argv[], int *width, int *height, int *fps, BOOL *exclusive) {
  if (argc != 4 && argc != 5) {
    return NO;
  }

  *exclusive = NO;
  if (argc == 5) {
    if (strcmp(argv[4], "exclusive") == 0) {
      *exclusive = YES;
    } else if (strcmp(argv[4], "extend") != 0) {
      return NO;
    }
  }

  *width = atoi(argv[1]);
  *height = atoi(argv[2]);
  *fps = atoi(argv[3]);
  return *width > 0 && *height > 0 && *fps > 0;
}

/**
 * @brief Create and hold a virtual display until its guardian requests shutdown.
 * @param argc Argument count.
 * @param argv Width, height, refresh rate, and optional display mode.
 * @return Zero after orderly cleanup, otherwise a startup error code.
 */
static int runDisplayHolder(int argc, const char *argv[]) {
  @autoreleasepool {
    // The holder owns the CGVirtualDisplay object. If its guardian exits,
    // launchd reparents this process and the display would otherwise remain
    // registered indefinitely.
    originalParentPID = getppid();

    if (!parentIsAlive()) {
      fprintf(stderr, "[vd_helper] No live Sunshine parent process found\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    int width = 0;
    int height = 0;
    int fps = 0;
    BOOL exclusiveMode = NO;
    if (!parseDisplayArguments(argc, argv, &width, &height, &fps, &exclusiveMode)) {
      fprintf(stderr, "[vd_helper] Invalid holder arguments\n");
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
        restoreOriginalDisplays(resultID, kCGConfigureForAppOnly);
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
        restoreOriginalDisplays(resultID, kCGConfigureForAppOnly);
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
        restoreOriginalDisplays(resultID, kCGConfigureForAppOnly);
      }
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (exclusiveMode && !applyExclusiveMode(resultID)) {
      fprintf(stderr, "[vd_helper] Could not enter exclusive display mode\n");
      restoreOriginalDisplays(resultID, kCGConfigureForAppOnly);
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (!parentIsAlive() || shouldExit) {
      fprintf(stderr, "[vd_helper] Parent exited before virtual display became ready\n");
      if (exclusiveMode) {
        restoreOriginalDisplays(resultID, kCGConfigureForAppOnly);
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

    if (exclusiveApplied && !restoreOriginalDisplays(resultID, kCGConfigureForAppOnly)) {
      fprintf(stderr, "[vd_helper] Display restoration during shutdown failed\n");
    }
    fprintf(stderr, "[vd_helper] Shutting down, releasing display %u\n", resultID);
    keepAlive = nil;
    keepDesc = nil;
  }
  return 0;
}

/** @brief Result of waiting for the holder's startup protocol. */
typedef enum {
  VD_HOLDER_START_READY,  ///< Holder reported a syntactically valid display ID.
  VD_HOLDER_START_EXITED,  ///< Holder exited and was reaped before reporting readiness.
  VD_HOLDER_START_ABORTED,  ///< Guardian shutdown began before holder readiness.
  VD_HOLDER_START_ERROR,  ///< Startup protocol or process inspection failed.
} vd_holder_start_result_t;

/**
 * @brief Read and validate the holder's single display-ID line.
 * @param descriptor Read end of the holder stdout pipe.
 * @param holderPID Holder process identifier.
 * @param displayID Receives the parsed display identifier, including zero on holder failure.
 * @param holderStatus Receives the holder wait status if it exits during startup.
 * @return Startup protocol result.
 */
static vd_holder_start_result_t readHolderDisplayID(int descriptor, pid_t holderPID, uint32_t *displayID, int *holderStatus) {
  static const unsigned int attempts = 90;
  static const suseconds_t interval = 100000;
  char buffer[64] = {0};
  size_t used = 0;

  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    if (shouldExit || !parentIsAlive()) {
      return VD_HOLDER_START_ABORTED;
    }

    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(descriptor, &readSet);
    struct timeval timeout = {0, interval};
    const int selected = select(descriptor + 1, &readSet, NULL, NULL, &timeout);
    if (selected > 0) {
      const ssize_t bytesRead = read(descriptor, buffer + used, sizeof(buffer) - used - 1);
      if (bytesRead < 0) {
        if (errno == EINTR) {
          continue;
        }
        return VD_HOLDER_START_ERROR;
      }
      if (bytesRead == 0) {
        const int state = vd_reap_child_if_exited(holderPID, holderStatus);
        return state == 1 ? VD_HOLDER_START_EXITED : VD_HOLDER_START_ERROR;
      }
      used += (size_t) bytesRead;
      buffer[used] = '\0';

      char *newline = memchr(buffer, '\n', used);
      if (newline) {
        *newline = '\0';
        char *end = NULL;
        errno = 0;
        const unsigned long parsed = strtoul(buffer, &end, 10);
        if (errno != 0 || end == buffer || end != newline || parsed > UINT32_MAX) {
          return VD_HOLDER_START_ERROR;
        }
        *displayID = (uint32_t) parsed;
        return VD_HOLDER_START_READY;
      }
      if (used == sizeof(buffer) - 1) {
        return VD_HOLDER_START_ERROR;
      }
    } else if (selected < 0 && errno != EINTR) {
      return VD_HOLDER_START_ERROR;
    }

    const int state = vd_reap_child_if_exited(holderPID, holderStatus);
    if (state == 1) {
      return VD_HOLDER_START_EXITED;
    }
    if (state < 0) {
      return VD_HOLDER_START_ERROR;
    }
  }
  return VD_HOLDER_START_ERROR;
}

/**
 * @brief Write the guardian's one-line startup result for Sunshine.
 * @param displayID Display identifier, or zero on failure.
 */
static void writeGuardianDisplayID(uint32_t displayID) {
  fprintf(stdout, "%u\n", displayID);
  fflush(stdout);
}

/**
 * @brief Supervise a separately spawned virtual-display holder.
 *
 * The guardian keeps an independent physical-display snapshot so it can
 * recover the desktop even if the holder is killed before its cleanup runs.
 *
 * @param argc Public helper argument count.
 * @param argv Public helper arguments.
 * @return Zero after an orderly shutdown, otherwise a startup or recovery error.
 */
static int runDisplayGuardian(int argc, const char *argv[]) {
  originalParentPID = getppid();
  if (!parentIsAlive()) {
    fprintf(stderr, "[vd_helper] Guardian has no live Sunshine parent process\n");
    writeGuardianDisplayID(0);
    return 1;
  }

  int width = 0;
  int height = 0;
  int fps = 0;
  BOOL exclusiveMode = NO;
  if (!parseDisplayArguments(argc, argv, &width, &height, &fps, &exclusiveMode)) {
    fprintf(stderr, "[vd_helper] Invalid guardian arguments\n");
    writeGuardianDisplayID(0);
    return 1;
  }

  char widthString[16];
  char heightString[16];
  char fpsString[16];
  snprintf(widthString, sizeof(widthString), "%d", width);
  snprintf(heightString, sizeof(heightString), "%d", height);
  snprintf(fpsString, sizeof(fpsString), "%d", fps);
  if (!installSignalHandlers()) {
    fprintf(stderr, "[vd_helper] Guardian could not install signal handlers: %s\n", strerror(errno));
    writeGuardianDisplayID(0);
    return 1;
  }
  if (exclusiveMode && !captureOriginalDisplays()) {
    writeGuardianDisplayID(0);
    return 1;
  }

  int pipefd[2];
  const int pipeError = vd_make_pipe(pipefd);
  if (pipeError != 0) {
    fprintf(stderr, "[vd_helper] Guardian could not create holder pipe: %s\n", strerror(pipeError));
    writeGuardianDisplayID(0);
    return 1;
  }

  const char *mode = exclusiveMode ? "exclusive" : "extend";
  const char *holderArguments[] = {
    argv[0],
    "--holder",
    widthString,
    heightString,
    fpsString,
    mode,
    NULL,
  };
  pid_t holderPID = 0;
  const int spawnError = vd_spawn_with_cloexec(&holderPID, argv[0], pipefd[1], pipefd[0], false, (char *const *) holderArguments, environ);
  close(pipefd[1]);
  if (spawnError != 0) {
    close(pipefd[0]);
    fprintf(stderr, "[vd_helper] Guardian could not spawn display holder: %s\n", strerror(spawnError));
    writeGuardianDisplayID(0);
    return 1;
  }
  fprintf(stderr, "[vd_helper] Guardian spawned display holder pid=%d\n", holderPID);

  uint32_t displayID = 0;
  int holderStatus = 0;
  const vd_holder_start_result_t startup = readHolderDisplayID(pipefd[0], holderPID, &displayID, &holderStatus);
  close(pipefd[0]);
  BOOL holderReaped = startup == VD_HOLDER_START_EXITED;

  if (startup != VD_HOLDER_START_READY || displayID == 0) {
    if (!holderReaped && !vd_terminate_and_reap(holderPID, 40, 20, 100000, &holderStatus)) {
      fprintf(stderr, "[vd_helper] Guardian could not reap failed holder pid=%d\n", holderPID);
    }
    if (exclusiveMode && !recoverOriginalDisplays(displayID)) {
      fprintf(stderr, "[vd_helper] Guardian recovery after holder startup failure failed\n");
    }
    if (!shouldExit && parentIsAlive()) {
      writeGuardianDisplayID(0);
    }
    return 1;
  }

  writeGuardianDisplayID(displayID);
  fprintf(stderr, "[vd_helper] Guardian relayed display %u from holder pid=%d\n", displayID, holderPID);

  BOOL holderExitedUnexpectedly = NO;
  while (!shouldExit && parentIsAlive()) {
    const int state = vd_reap_child_if_exited(holderPID, &holderStatus);
    if (state == 1) {
      holderReaped = YES;
      holderExitedUnexpectedly = YES;
      fprintf(stderr, "[vd_helper] Display holder pid=%d exited unexpectedly\n", holderPID);
      break;
    }
    if (state < 0) {
      holderExitedUnexpectedly = YES;
      fprintf(stderr, "[vd_helper] Could not inspect display holder pid=%d: %s\n", holderPID, strerror(errno));
      break;
    }
    usleep(100000);
  }

  if (!holderReaped && !vd_terminate_and_reap(holderPID, 30, 20, 100000, &holderStatus)) {
    fprintf(stderr, "[vd_helper] Guardian could not stop and reap holder pid=%d\n", holderPID);
    holderExitedUnexpectedly = YES;
  }

  BOOL restored = YES;
  if (exclusiveMode) {
    restored = recoverOriginalDisplays(displayID);
    if (!restored) {
      fprintf(stderr, "[vd_helper] Guardian could not restore the saved physical displays\n");
    }
  }

  return holderExitedUnexpectedly || !restored ? 1 : 0;
}

/**
 * @brief Select guardian or hidden holder mode.
 * @param argc Argument count.
 * @param argv Helper arguments.
 * @return Process exit status.
 */
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc > 1 && strcmp(argv[1], "--holder") == 0) {
      return runDisplayHolder(argc - 1, argv + 1);
    }
    return runDisplayGuardian(argc, argv);
  }
}
