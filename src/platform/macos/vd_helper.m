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
#include "display_preferences.h"
#include "vd_helper_mode_policy.h"
#include "vd_helper_policy.h"
#include "vd_spawn.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <signal.h>
#include <stdatomic.h>
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

/**
 * @brief Scoped assertion that prevents display sleep during helper work.
 */
@interface VDDisplayPowerGuard: NSObject {
@private
  IOPMAssertionID _assertionID;  ///< Assertion released when the guard leaves scope.
}

/**
 * @brief Create a display-sleep prevention assertion.
 * @param reason Human-readable assertion reason.
 * @return Initialized guard, or nil when macOS rejects the assertion.
 */
- (instancetype)initWithReason:(NSString *)reason;
@end

@implementation VDDisplayPowerGuard

- (instancetype)initWithReason:(NSString *)reason {
  self = [super init];
  if (!self) {
    return nil;
  }

  _assertionID = kIOPMNullAssertionID;
  const IOReturn result = IOPMAssertionCreateWithName(
    kIOPMAssertPreventUserIdleDisplaySleep,
    kIOPMAssertionLevelOn,
    (__bridge CFStringRef) reason,
    &_assertionID
  );
  if (result != kIOReturnSuccess) {
    fprintf(stderr, "[vd_helper] Could not prevent display sleep: 0x%x\n", result);
    return nil;
  }
  return self;
}

/**
 * @brief Release the display-sleep prevention assertion.
 */
- (void)dealloc {
  if (_assertionID != kIOPMNullAssertionID) {
    const IOReturn result = IOPMAssertionRelease(_assertionID);
    if (result != kIOReturnSuccess) {
      fprintf(stderr, "[vd_helper] Could not release display-sleep assertion %u: 0x%x\n", _assertionID, result);
    }
  }
}

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
static CGDirectDisplayID originalDisplayIDs[64];  ///< Ordinary displays active before creation.
static uint32_t originalDisplayCount = 0;  ///< Number of saved display IDs.
static CGDirectDisplayID originalOnlineDisplayIDs[64];  ///< Ordinary displays online before creation.
static uint32_t originalOnlineDisplayCount = 0;  ///< Number of saved online display IDs.
static BOOL exclusiveApplied = NO;  ///< Whether physical displays were disabled.

/**
 * @brief Parsed request shared by the guardian and holder processes.
 */
typedef struct display_request_t {
  macos_display_requested_mode_t requested;  ///< Moonlight tuple that initiated the request.
  macos_display_mode_t effective;  ///< Logical/backing mode to offer and select.
  uint32_t helper_serial;  ///< Stable serial for this paired client, or zero for legacy callers.
  const char *profile_directory;  ///< Profile directory for the holder's mode snapshot.
  const char *certificate_fingerprint;  ///< Paired client certificate fingerprint, or an empty string.
  BOOL exclusive;  ///< Whether physical displays are temporarily disabled.
} display_request_t;

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
 * @brief Identify a known transient virtual display seen during recovery.
 *
 * Recovery probes identified the exact vendor/model pairs `unkn`/`virt` for
 * the macOS fallback and `F0F0`/`5678` for an orphaned Sunshine display.
 * Ordinary physical displays and all other virtual displays are retained.
 *
 * @param displayID Display identifier to classify.
 * @return YES only for one of the observed transient virtual-display signatures.
 */
static BOOL isKnownTransientVirtualDisplay(CGDirectDisplayID displayID) {
  return vd_helper_is_known_transient_virtual_display(CGDisplayVendorNumber(displayID), CGDisplayModelNumber(displayID));
}

/**
 * @brief Check whether WindowServer currently reports an ordinary active display.
 * @return YES when at least one active display is not a known transient virtual display.
 */
static BOOL ordinaryDisplayIsActive(void) {
  CGDirectDisplayID activeDisplays[64];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(64, activeDisplays, &displayCount) != kCGErrorSuccess) {
    return NO;
  }
  for (uint32_t index = 0; index < displayCount; ++index) {
    if (!isKnownTransientVirtualDisplay(activeDisplays[index])) {
      return YES;
    }
  }
  return NO;
}

/**
 * @brief Wake the display system before taking the guardian's physical snapshot.
 *
 * User activity is declared unconditionally because macOS can report a
 * fallback or orphaned virtual display as active while the physical display is
 * asleep. The bounded wait permits a physical display to reappear without
 * preventing a genuinely headless host from continuing.
 */
static void wakeDisplayBeforeSnapshot(void) {
  IOPMAssertionID activityAssertionID = kIOPMNullAssertionID;
  const IOReturn result = IOPMAssertionDeclareUserActivity(
    CFSTR("Sunshine virtual display setup"),
    kIOPMUserActiveRemote,
    &activityAssertionID
  );
  if (result != kIOReturnSuccess) {
    fprintf(stderr, "[vd_helper] Could not declare remote user activity: 0x%x\n", result);
    return;
  }

  static const unsigned int attempts = 10;
  static const CFTimeInterval interval = 0.05;
  for (unsigned int attempt = 0; attempt < attempts && !ordinaryDisplayIsActive(); ++attempt) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, interval, false);
  }

  const IOReturn releaseResult = IOPMAssertionRelease(activityAssertionID);
  if (releaseResult != kIOReturnSuccess) {
    fprintf(stderr, "[vd_helper] Could not release user-activity assertion %u: 0x%x\n", activityAssertionID, releaseResult);
  }
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
  uint32_t filteredActiveCount = 0;
  for (uint32_t index = 0; index < originalDisplayCount; ++index) {
    const CGDirectDisplayID displayID = originalDisplayIDs[index];
    if (isKnownTransientVirtualDisplay(displayID)) {
      fprintf(stderr, "[vd_helper] Ignoring transient virtual display %u in active snapshot\n", displayID);
      continue;
    }
    originalDisplayIDs[filteredActiveCount++] = displayID;
  }
  originalDisplayCount = filteredActiveCount;

  error = CGGetOnlineDisplayList(64, originalOnlineDisplayIDs, &originalOnlineDisplayCount);
  if (error != kCGErrorSuccess) {
    fprintf(stderr, "[vd_helper] Could not snapshot online displays: %d\n", error);
    originalDisplayCount = 0;
    originalOnlineDisplayCount = 0;
    return NO;
  }
  uint32_t filteredOnlineCount = 0;
  for (uint32_t index = 0; index < originalOnlineDisplayCount; ++index) {
    const CGDirectDisplayID displayID = originalOnlineDisplayIDs[index];
    if (isKnownTransientVirtualDisplay(displayID)) {
      fprintf(stderr, "[vd_helper] Ignoring transient virtual display %u in online snapshot\n", displayID);
      continue;
    }
    originalOnlineDisplayIDs[filteredOnlineCount++] = displayID;
  }
  originalOnlineDisplayCount = filteredOnlineCount;
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
  if (CGGetActiveDisplayList(64, activeDisplays, &displayCount) != kCGErrorSuccess) {
    return NO;
  }
  return vd_helper_active_list_is_only_target(activeDisplays, displayCount, virtualID);
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
    if (activeDisplays[activeIndex] == virtualID || isKnownTransientVirtualDisplay(activeDisplays[activeIndex])) {
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
  // When no ordinary display was captured, the filtered snapshot represents a
  // headless or transient-only baseline.  Avoid an empty transaction in that
  // case, while retaining the transaction for every physical baseline so a
  // stale CoreGraphics active-list cache cannot hide a missing display.
  if (originalDisplayCount == 0 && originalOnlineDisplayCount == 0) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    if (originalDisplaysAreActive(virtualID)) {
      fprintf(stderr, "[vd_helper] No ordinary display state requires restoration; skipping empty transaction\n");
      return YES;
    }
  }

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
 * @brief Restore saved physical displays when holder cleanup has not done so.
 * @param virtualID Last virtual display identifier reported by the holder.
 * @return YES when the saved physical display set was restored.
 * @details Let pending WindowServer notifications settle before deciding whether
 *          a recovery transaction is still needed.
 */
static BOOL recoverOriginalDisplays(CGDirectDisplayID virtualID) {
  static const unsigned int attempts = 3;
  static const CFTimeInterval settleInterval = 0.05;

  CFRunLoopRunInMode(kCFRunLoopDefaultMode, settleInterval, false);
  if (originalDisplaysAreActive(virtualID)) {
    return YES;
  }

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

  // A previous cleanup or WindowServer transition may already have left the
  // requested strict virtual-only state.  Do not reopen a configuration just
  // to disable physical displays that are already inactive.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
  if (onlyVirtualDisplayActive(virtualID)) {
    fprintf(stderr, "[vd_helper] Exclusive display state is already active; skipping configuration transaction\n");
    exclusiveApplied = YES;
    return YES;
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
 * @brief Parse a bounded unsigned integer from helper arguments.
 * @param value Argument text.
 * @param output Receives the parsed value.
 * @return YES when the complete argument is a positive unsigned integer.
 */
static BOOL parseUnsignedArgument(const char *value, uint32_t *output) {
  if (!value || !output || *value == '\0') {
    return NO;
  }

  char *end = NULL;
  errno = 0;
  const unsigned long parsed = strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed == 0 || parsed > UINT32_MAX) {
    return NO;
  }
  *output = (uint32_t) parsed;
  return YES;
}

/**
 * @brief Parse a non-negative unsigned integer from helper arguments.
 * @param value Argument text.
 * @param output Receives the parsed value.
 * @return YES when the complete argument is an unsigned integer.
 */
static BOOL parseUnsignedArgumentAllowZero(const char *value, uint32_t *output) {
  if (!value || !output || *value == '\0') {
    return NO;
  }

  char *end = NULL;
  errno = 0;
  const unsigned long parsed = strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
    return NO;
  }
  *output = (uint32_t) parsed;
  return YES;
}

/**
 * @brief Parse a bounded refresh rate from helper arguments.
 * @param value Argument text.
 * @param output Receives the parsed rate.
 * @return YES when the complete argument is a finite positive refresh rate.
 */
static BOOL parseRefreshArgument(const char *value, double *output) {
  if (!value || !output || *value == '\0') {
    return NO;
  }

  char *end = NULL;
  errno = 0;
  const double parsed = strtod(value, &end);
  if (errno != 0 || end == value || *end != '\0' || !isfinite(parsed) || parsed <= 0.0 || parsed > MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE) {
    return NO;
  }
  *output = parsed;
  return YES;
}

/**
 * @brief Parse and validate the display request shared by guardian and holder.
 * @param argc Argument count in the public helper layout.
 * @param argv Executable name followed by request fields and optional mode.
 * @param request Receives the parsed request.
 * @return YES when every argument is valid.
 *
 * The four-argument form remains available for direct helper diagnostics. The
 * extended form carries the requested tuple, effective logical/backing mode,
 * stable serial, and the holder's profile context.
 */
static BOOL parseDisplayArguments(int argc, const char *argv[], display_request_t *request) {
  if (!request || (argc != 4 && argc != 5 && argc != 14)) {
    return NO;
  }
  memset(request, 0, sizeof(*request));

  const char *mode = "extend";
  if (argc == 5) {
    mode = argv[4];
  } else if (argc == 14) {
    mode = argv[13];
  }
  if (strcmp(mode, "exclusive") == 0) {
    request->exclusive = YES;
  } else if (strcmp(mode, "extend") != 0) {
    return NO;
  }

  if (!parseUnsignedArgument(argv[1], &request->requested.width) || !parseUnsignedArgument(argv[2], &request->requested.height) || !parseUnsignedArgument(argv[3], &request->requested.refresh_rate) || request->requested.width > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || request->requested.height > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || request->requested.refresh_rate > MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE) {
    return NO;
  }

  if (argc == 4 || argc == 5) {
    request->effective.logical_width = request->requested.width;
    request->effective.logical_height = request->requested.height;
    request->effective.pixel_width = request->requested.width;
    request->effective.pixel_height = request->requested.height;
    request->effective.refresh_rate = (double) request->requested.refresh_rate;
    request->effective.hidpi = NO;
    request->profile_directory = "";
    request->certificate_fingerprint = "";
    return YES;
  }

  if (!parseUnsignedArgument(argv[4], &request->effective.logical_width) || !parseUnsignedArgument(argv[5], &request->effective.logical_height) || !parseUnsignedArgument(argv[6], &request->effective.pixel_width) || !parseUnsignedArgument(argv[7], &request->effective.pixel_height) || !parseRefreshArgument(argv[8], &request->effective.refresh_rate) || (strcmp(argv[9], "0") != 0 && strcmp(argv[9], "1") != 0) || !parseUnsignedArgumentAllowZero(argv[10], &request->helper_serial) || request->effective.logical_width > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || request->effective.logical_height > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || request->effective.pixel_width > MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION || request->effective.pixel_height > MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION || request->effective.pixel_width < request->effective.logical_width || request->effective.pixel_height < request->effective.logical_height) {
    return NO;
  }

  request->effective.hidpi = strcmp(argv[9], "1") == 0;
  if (request->effective.hidpi != (request->effective.pixel_width != request->effective.logical_width || request->effective.pixel_height != request->effective.logical_height)) {
    return NO;
  }
  request->profile_directory = argv[11];
  request->certificate_fingerprint = argv[12];
  return YES;
}

/**
 * @brief Check whether a CoreGraphics mode snapshot is complete and bounded.
 * @param mode Mode snapshot to validate.
 * @return YES when the snapshot can be persisted.
 */
static BOOL validModeSnapshot(const macos_display_mode_t *mode) {
  if (!mode) {
    return NO;
  }
  const BOOL scaled = mode->pixel_width != mode->logical_width || mode->pixel_height != mode->logical_height;
  return mode->logical_width > 0 && mode->logical_width <= MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION &&
         mode->logical_height > 0 && mode->logical_height <= MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION &&
         mode->pixel_width > 0 && mode->pixel_width <= MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION &&
         mode->pixel_height > 0 && mode->pixel_height <= MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION &&
         mode->pixel_width >= mode->logical_width && mode->pixel_height >= mode->logical_height &&
         isfinite(mode->refresh_rate) && mode->refresh_rate > 0.0 && mode->refresh_rate <= MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE &&
         mode->hidpi == scaled;
}

/**
 * @brief Read the active mode from the holder's CoreGraphics process.
 * @param displayID Display identifier to inspect.
 * @param mode Receives logical, backing, refresh, and HiDPI details.
 * @return YES when CoreGraphics returned a complete mode.
 */
static BOOL readCurrentDisplayMode(CGDirectDisplayID displayID, macos_display_mode_t *mode) {
  if (!mode || !CGDisplayIsOnline(displayID) || !CGDisplayIsActive(displayID)) {
    return NO;
  }

  CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
  if (!current) {
    return NO;
  }

  const size_t logicalWidth = CGDisplayModeGetWidth(current);
  const size_t logicalHeight = CGDisplayModeGetHeight(current);
  const size_t pixelWidth = CGDisplayModeGetPixelWidth(current);
  const size_t pixelHeight = CGDisplayModeGetPixelHeight(current);
  const double refreshRate = CGDisplayModeGetRefreshRate(current);
  CFRelease(current);
  if (logicalWidth > UINT32_MAX || logicalHeight > UINT32_MAX || pixelWidth > UINT32_MAX || pixelHeight > UINT32_MAX) {
    return NO;
  }

  *mode = (macos_display_mode_t) {
    (uint32_t) logicalWidth,
    (uint32_t) logicalHeight,
    (uint32_t) pixelWidth,
    (uint32_t) pixelHeight,
    refreshRate,
    pixelWidth != logicalWidth || pixelHeight != logicalHeight
  };
  return validModeSnapshot(mode);
}

/** @brief Callback state for one holder-owned virtual display. */
typedef struct display_reconfiguration_context_t {
  CGDirectDisplayID display_id;  ///< Virtual display whose configuration is tracked.
  atomic_bool mode_change_pending;  ///< Whether CoreGraphics delivered a completed reconfiguration.
} display_reconfiguration_context_t;

/**
 * @brief Notice completed CoreGraphics reconfiguration events for the held display.
 * @param display Display associated with the callback.
 * @param flags Summary of the display configuration changes.
 * @param userInfo Pointer to the holder's reconfiguration context.
 */
static void displayReconfigurationCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
  display_reconfiguration_context_t *context = userInfo;
  if (!context || display != context->display_id || (flags & kCGDisplayBeginConfigurationFlag) != 0) {
    return;
  }
  atomic_store_explicit(&context->mode_change_pending, true, memory_order_release);
}

/**
 * @brief Process AppKit events for a bounded interval on the holder's main thread.
 *
 * CoreGraphics delivers display reconfiguration callbacks to applications that
 * are listening for events on their event-processing thread. Running the bare
 * Core Foundation run loop does not dispatch the AppKit event queue.
 *
 * @param interval Maximum number of seconds to process events.
 */
static void pumpApplicationEvents(NSTimeInterval interval) {
  @autoreleasepool {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(interval, 0.0)];
    while (!shouldExit && [deadline timeIntervalSinceNow] > 0.0) {
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:deadline
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (!event) {
        break;
      }
      [NSApp sendEvent:event];
    }
  }
}

/**
 * @brief Add one unique virtual-display mode to a settings list.
 * @param modes Mutable settings mode list.
 * @param widths Widths already represented in the list.
 * @param heights Heights already represented in the list.
 * @param refreshRates Refresh rates already represented in the list.
 * @param modeCount Number of populated entries in the parallel arrays.
 * @param width Mode width.
 * @param height Mode height.
 * @param refreshRate Mode refresh rate.
 * @return YES when the mode already existed or was added successfully.
 */
static BOOL appendVirtualDisplayMode(
  NSMutableArray *modes,
  unsigned int widths[6],
  unsigned int heights[6],
  double refreshRates[6],
  NSUInteger *modeCount,
  unsigned int width,
  unsigned int height,
  double refreshRate
) {
  if (!modes || !modeCount || width == 0 || height == 0) {
    return NO;
  }
  for (NSUInteger index = 0; index < *modeCount; ++index) {
    if (widths[index] == width && heights[index] == height && fabs(refreshRates[index] - refreshRate) <= 0.01) {
      return YES;
    }
  }
  if (*modeCount >= 6) {
    return NO;
  }

  CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshRate];
  if (!mode) {
    return NO;
  }
  [modes addObject:mode];
  widths[*modeCount] = width;
  heights[*modeCount] = height;
  refreshRates[*modeCount] = refreshRate;
  ++*modeCount;
  return YES;
}

/**
 * @brief Select the requested logical/backing mode from the virtual display's mode list.
 * @param displayID Display identifier to configure.
 * @param request Effective mode requested by the guardian.
 * @return YES when an exact or logical-dimension match was applied.
 */
static BOOL selectRequestedDisplayMode(CGDirectDisplayID displayID, const display_request_t *request) {
  if (!request) {
    return NO;
  }

  NSDictionary *options = @{(NSString *) kCGDisplayShowDuplicateLowResolutionModes: @YES};
  CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (CFDictionaryRef) options);
  if (!allModes) {
    return NO;
  }

  CGDisplayModeRef logicalMatch = NULL;
  CGDisplayModeRef exactMatch = NULL;
  const CFIndex modeCount = CFArrayGetCount(allModes);
  for (CFIndex index = 0; index < modeCount; ++index) {
    CGDisplayModeRef candidate = (CGDisplayModeRef) CFArrayGetValueAtIndex(allModes, index);
    if (!candidate) {
      continue;
    }
    const size_t logicalWidth = CGDisplayModeGetWidth(candidate);
    const size_t logicalHeight = CGDisplayModeGetHeight(candidate);
    const size_t pixelWidth = CGDisplayModeGetPixelWidth(candidate);
    const size_t pixelHeight = CGDisplayModeGetPixelHeight(candidate);
    if (logicalWidth != request->effective.logical_width || logicalHeight != request->effective.logical_height) {
      continue;
    }
    const double refreshRate = CGDisplayModeGetRefreshRate(candidate);
    if (refreshRate > 0.0 && fabs(refreshRate - request->effective.refresh_rate) > 1.0) {
      continue;
    }
    if (!logicalMatch) {
      logicalMatch = candidate;
    }
    if (pixelWidth == request->effective.pixel_width && pixelHeight == request->effective.pixel_height) {
      exactMatch = candidate;
      break;
    }
  }

  CGDisplayModeRef selected = exactMatch ? exactMatch : logicalMatch;
  BOOL success = NO;
  if (selected) {
    const CGError error = CGDisplaySetDisplayMode(displayID, selected, NULL);
    success = error == kCGErrorSuccess;
    fprintf(stderr, "[vd_helper] Selected %s mode %ux%u logical (%ux%u pixels, %.3fHz): %d\n", exactMatch ? "exact" : "logical fallback", request->effective.logical_width, request->effective.logical_height, request->effective.pixel_width, request->effective.pixel_height, request->effective.refresh_rate, error);
  } else {
    fprintf(stderr, "[vd_helper] Requested mode %ux%u logical (%ux%u pixels, %.3fHz) was not found\n", request->effective.logical_width, request->effective.logical_height, request->effective.pixel_width, request->effective.pixel_height, request->effective.refresh_rate);
  }
  CFRelease(allModes);
  return success;
}

/**
 * @brief Persist a changed full-mode snapshot while the holder owns the display.
 * @param request Request and profile context for the current client.
 * @param mode Validated mode to write for the request's resolution mapping.
 * @return YES when the changed mode was written.
 */
static BOOL saveChangedDisplayMode(
  const display_request_t *request,
  const macos_display_mode_t *mode
) {
  if (!request || !validModeSnapshot(mode) || !request->profile_directory || !request->certificate_fingerprint || request->profile_directory[0] == '\0' || request->certificate_fingerprint[0] == '\0') {
    return NO;
  }

  const macos_display_preference_t preference = {
    request->requested,
    *mode
  };
  if (!macos_display_preferences_save(request->profile_directory, request->certificate_fingerprint, &preference)) {
    fprintf(stderr, "[vd_helper] Could not persist changed virtual-display mode\n");
    return NO;
  }
  fprintf(stderr, "[vd_helper] Persisted changed virtual-display mode %ux%u logical (%ux%u pixels, %.3fHz)\n", mode->logical_width, mode->logical_height, mode->pixel_width, mode->pixel_height, mode->refresh_rate);
  return YES;
}

/**
 * @brief Observe and persist a live full-mode snapshot when its dimensions changed.
 * @param displayID Virtual display identifier to inspect.
 * @param request Request and profile context for the current client.
 * @param tracker Last observed and pending-to-save mode state.
 * @param phase Human-readable observation phase for diagnostics.
 * @param readFailureLogged Tracks whether a repeated read failure was already reported.
 * @param changed Receives whether this observation changed dimensions or HiDPI state.
 * @return YES when a complete current mode was observed.
 */
static BOOL observeAndPersistDisplayMode(
  CGDirectDisplayID displayID,
  const display_request_t *request,
  vd_helper_mode_tracker_t *tracker,
  const char *phase,
  BOOL *readFailureLogged,
  BOOL *changed
) {
  if (changed) {
    *changed = NO;
  }
  if (!request || !tracker) {
    return NO;
  }

  macos_display_mode_t current = {};
  if (!readCurrentDisplayMode(displayID, &current)) {
    if (!readFailureLogged || !*readFailureLogged) {
      fprintf(stderr, "[vd_helper] Could not read a complete %s display mode; retaining the last valid observation\n", phase ? phase : "live");
    }
    if (readFailureLogged) {
      *readFailureLogged = YES;
    }
    return NO;
  }
  if (readFailureLogged) {
    *readFailureLogged = NO;
  }

  const BOOL hadObservation = tracker->has_last_observed;
  const BOOL modeChanged = vd_helper_mode_tracker_observe(tracker, &current, true);
  if (!hadObservation) {
    fprintf(stderr, "[vd_helper] Captured delayed baseline display mode %ux%u logical (%ux%u pixels, %.3fHz)\n", current.logical_width, current.logical_height, current.pixel_width, current.pixel_height, current.refresh_rate);
  } else if (modeChanged) {
    fprintf(stderr, "[vd_helper] Observed changed virtual-display mode %ux%u logical (%ux%u pixels, %.3fHz)\n", current.logical_width, current.logical_height, current.pixel_width, current.pixel_height, current.refresh_rate);
  }
  if (changed) {
    *changed = modeChanged;
  }

  if (tracker->has_dirty_mode && saveChangedDisplayMode(request, &tracker->dirty_mode)) {
    vd_helper_mode_tracker_mark_saved(tracker);
  }
  return YES;
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

    display_request_t request = {};
    if (!parseDisplayArguments(argc, argv, &request)) {
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

    __attribute__((objc_precise_lifetime)) VDDisplayPowerGuard *displayPowerGuard = request.exclusive ? [[VDDisplayPowerGuard alloc] initWithReason:@"Sunshine exclusive virtual display holder"] : nil;
    (void) displayPowerGuard;

    if (request.exclusive && !captureOriginalDisplays()) {
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
    [NSApp finishLaunching];

    // Create display directly on main thread
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = @"Sunshine Virtual Display";
    desc.vendorID = 0xF0F0;
    desc.productID = 0x5678;
    desc.serialNum = request.helper_serial != 0 ? request.helper_serial : arc4random();
    desc.maxPixelsWide = MAX(request.requested.width, request.effective.pixel_width);
    desc.maxPixelsHigh = MAX(request.requested.height, request.effective.pixel_height);
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

    // Keep the original client-native pair available even when a saved mode
    // uses a smaller backing store. This lets the user return to the original
    // resolution in macOS Displays without first deleting the preference.
    NSMutableArray *availableModes = [NSMutableArray arrayWithCapacity:6];
    unsigned int modeWidths[6] = {0};
    unsigned int modeHeights[6] = {0};
    double modeRefreshRates[6] = {0};
    NSUInteger modeCount = 0;
    BOOL modesValid = appendVirtualDisplayMode(availableModes, modeWidths, modeHeights, modeRefreshRates, &modeCount, request.effective.pixel_width, request.effective.pixel_height, request.effective.refresh_rate);
    if (request.effective.pixel_width >= 2 && request.effective.pixel_height >= 2) {
      modesValid = modesValid && appendVirtualDisplayMode(availableModes, modeWidths, modeHeights, modeRefreshRates, &modeCount, request.effective.pixel_width / 2, request.effective.pixel_height / 2, request.effective.refresh_rate);
    }
    const BOOL targetIsNative = request.effective.logical_width == request.effective.pixel_width &&
                                request.effective.logical_height == request.effective.pixel_height;
    const BOOL targetIsHalf = request.effective.pixel_width == request.effective.logical_width * 2 &&
                              request.effective.pixel_height == request.effective.logical_height * 2;
    if (!targetIsNative && !targetIsHalf) {
      modesValid = modesValid && appendVirtualDisplayMode(availableModes, modeWidths, modeHeights, modeRefreshRates, &modeCount, request.effective.logical_width, request.effective.logical_height, request.effective.refresh_rate);
    }
    modesValid = modesValid && appendVirtualDisplayMode(availableModes, modeWidths, modeHeights, modeRefreshRates, &modeCount, request.requested.width, request.requested.height, request.requested.refresh_rate);
    if (request.requested.width >= 2 && request.requested.height >= 2) {
      modesValid = modesValid && appendVirtualDisplayMode(availableModes, modeWidths, modeHeights, modeRefreshRates, &modeCount, request.requested.width / 2, request.requested.height / 2, request.requested.refresh_rate);
    }
    if (!modesValid || modeCount == 0) {
      fprintf(stderr, "[vd_helper] Failed to create CGVirtualDisplayMode list\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    settings.modes = availableModes;

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

    if (!parentIsAlive() || shouldExit || !activateVirtualDisplay(resultID, request.exclusive)) {
      fprintf(stderr, "[vd_helper] Virtual display activation failed\n");
      if (request.exclusive) {
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
      if (request.exclusive) {
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

    // Step 3: Select the logical/backing mode requested by the client profile.
    // The default request selects the native 1x mode. A saved HiDPI mode selects
    // the matching logical half-resolution mode when WindowServer exposes it.
    (void) selectRequestedDisplayMode(resultID, &request);

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

    fprintf(stderr, "[vd_helper] Display %u (%ux%u@%uHz requested) - %s in active list (%u total)\n", resultID, request.requested.width, request.requested.height, request.requested.refresh_rate, found ? "FOUND" : "NOT found", count);

    if (!waitForDisplayReady(resultID)) {
      fprintf(stderr, "[vd_helper] Display %u did not become online and active\n", resultID);
      if (request.exclusive) {
        restoreOriginalDisplays(resultID, kCGConfigureForAppOnly);
      }
      keepAlive = nil;
      keepDesc = nil;
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (request.exclusive && !applyExclusiveMode(resultID)) {
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
      if (request.exclusive) {
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

    // Register before the first snapshot. CoreGraphics guarantees its display
    // state is current when it delivers a completed reconfiguration callback.
    display_reconfiguration_context_t reconfigurationContext = {resultID};
    atomic_init(&reconfigurationContext.mode_change_pending, false);
    const CGError callbackError = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, &reconfigurationContext);
    const BOOL callbackRegistered = callbackError == kCGErrorSuccess;
    if (!callbackRegistered) {
      fprintf(stderr, "[vd_helper] Could not register display reconfiguration callback: %d; falling back to polling\n", callbackError);
    }

    // Let activation and exclusive-mode notifications settle. WindowServer can
    // restore a mode remembered for this serial after the earlier selection, so
    // enforce the requested effective mode once more before fixing the baseline.
    pumpApplicationEvents(0.25);
    macos_display_mode_t settledMode = {};
    if (readCurrentDisplayMode(resultID, &settledMode) && !vd_helper_effective_mode_matches(&settledMode, &request.effective)) {
      fprintf(stderr, "[vd_helper] Reapplying requested mode after WindowServer restored %ux%u logical (%ux%u pixels, %.3fHz)\n", settledMode.logical_width, settledMode.logical_height, settledMode.pixel_width, settledMode.pixel_height, settledMode.refresh_rate);
      (void) selectRequestedDisplayMode(resultID, &request);
      pumpApplicationEvents(0.25);
    }

    // Capture the post-startup baseline here so the startup-selected mode is
    // not mistaken for a user-selected mode during live observation.
    macos_display_mode_t baselineMode = {};
    vd_helper_mode_tracker_t modeTracker = {};
    const BOOL baselineAvailable = readCurrentDisplayMode(resultID, &baselineMode);
    if (baselineAvailable) {
      (void) vd_helper_mode_tracker_observe(&modeTracker, &baselineMode, true);
      fprintf(stderr, "[vd_helper] Captured baseline display mode %ux%u logical (%ux%u pixels, %.3fHz)\n", baselineMode.logical_width, baselineMode.logical_height, baselineMode.pixel_width, baselineMode.pixel_height, baselineMode.refresh_rate);
    } else {
      fprintf(stderr, "[vd_helper] Could not read a complete baseline display mode; waiting for a later full snapshot\n");
    }
    atomic_store_explicit(&reconfigurationContext.mode_change_pending, false, memory_order_release);
    const BOOL persistenceAvailable = request.profile_directory && request.certificate_fingerprint && request.profile_directory[0] != '\0' && request.certificate_fingerprint[0] != '\0';
    if (!persistenceAvailable) {
      fprintf(stderr, "[vd_helper] Display-mode persistence unavailable because client profile context is absent\n");
    }
    BOOL liveReadFailureLogged = NO;

    fprintf(stdout, "%u\n", resultID);
    fflush(stdout);

    // Keep alive via CFRunLoop
    while (!shouldExit) {
      if (!parentIsAlive()) {
        fprintf(stderr, "[vd_helper] Parent process %d exited; shutting down\n", originalParentPID);
        shouldExit = 1;
        break;
      }
      pumpApplicationEvents(1.0);
      const BOOL callbackPending = atomic_exchange_explicit(&reconfigurationContext.mode_change_pending, false, memory_order_acq_rel);
      if (callbackPending) {
        fprintf(stderr, "[vd_helper] Processing display reconfiguration notification\n");
      }
      if (persistenceAvailable && !shouldExit) {
        (void) observeAndPersistDisplayMode(resultID, &request, &modeTracker, callbackPending ? "reconfigured" : "live", &liveReadFailureLogged, NULL);
      }
    }

    // Take a final full snapshot before restoring physical displays or releasing
    // the virtual display. An invalid read retains any last valid dirty mode.
    if (persistenceAvailable) {
      BOOL finalChanged = NO;
      const BOOL finalRead = observeAndPersistDisplayMode(resultID, &request, &modeTracker, "shutdown", NULL, &finalChanged);
      if (finalRead && !finalChanged && !modeTracker.has_dirty_mode) {
        fprintf(stderr, "[vd_helper] Final virtual-display mode is unchanged since the last valid observation\n");
      } else if (!finalRead && modeTracker.has_dirty_mode && saveChangedDisplayMode(&request, &modeTracker.dirty_mode)) {
        vd_helper_mode_tracker_mark_saved(&modeTracker);
      }
    }

    if (callbackRegistered) {
      const CGError removalError = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, &reconfigurationContext);
      if (removalError != kCGErrorSuccess) {
        fprintf(stderr, "[vd_helper] Could not remove display reconfiguration callback: %d\n", removalError);
      }
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

  display_request_t request = {};
  if (!parseDisplayArguments(argc, argv, &request)) {
    fprintf(stderr, "[vd_helper] Invalid guardian arguments\n");
    writeGuardianDisplayID(0);
    return 1;
  }

  char requestedWidthString[16];
  char requestedHeightString[16];
  char requestedRefreshString[16];
  char logicalWidthString[16];
  char logicalHeightString[16];
  char pixelWidthString[16];
  char pixelHeightString[16];
  char effectiveRefreshString[32];
  char hidpiString[2];
  char serialString[16];
  snprintf(requestedWidthString, sizeof(requestedWidthString), "%u", request.requested.width);
  snprintf(requestedHeightString, sizeof(requestedHeightString), "%u", request.requested.height);
  snprintf(requestedRefreshString, sizeof(requestedRefreshString), "%u", request.requested.refresh_rate);
  snprintf(logicalWidthString, sizeof(logicalWidthString), "%u", request.effective.logical_width);
  snprintf(logicalHeightString, sizeof(logicalHeightString), "%u", request.effective.logical_height);
  snprintf(pixelWidthString, sizeof(pixelWidthString), "%u", request.effective.pixel_width);
  snprintf(pixelHeightString, sizeof(pixelHeightString), "%u", request.effective.pixel_height);
  snprintf(effectiveRefreshString, sizeof(effectiveRefreshString), "%.6f", request.effective.refresh_rate);
  snprintf(hidpiString, sizeof(hidpiString), "%d", request.effective.hidpi ? 1 : 0);
  snprintf(serialString, sizeof(serialString), "%u", request.helper_serial);
  if (!installSignalHandlers()) {
    fprintf(stderr, "[vd_helper] Guardian could not install signal handlers: %s\n", strerror(errno));
    writeGuardianDisplayID(0);
    return 1;
  }
  __attribute__((objc_precise_lifetime)) VDDisplayPowerGuard *displayPowerGuard = request.exclusive ? [[VDDisplayPowerGuard alloc] initWithReason:@"Sunshine exclusive virtual display guardian"] : nil;
  (void) displayPowerGuard;
  if (request.exclusive) {
    wakeDisplayBeforeSnapshot();
    if (!captureOriginalDisplays()) {
      writeGuardianDisplayID(0);
      return 1;
    }
  }

  int pipefd[2];
  const int pipeError = vd_make_pipe(pipefd);
  if (pipeError != 0) {
    fprintf(stderr, "[vd_helper] Guardian could not create holder pipe: %s\n", strerror(pipeError));
    writeGuardianDisplayID(0);
    return 1;
  }

  const char *mode = request.exclusive ? "exclusive" : "extend";
  const char *holderArguments[] = {
    argv[0],
    "--holder",
    requestedWidthString,
    requestedHeightString,
    requestedRefreshString,
    logicalWidthString,
    logicalHeightString,
    pixelWidthString,
    pixelHeightString,
    effectiveRefreshString,
    hidpiString,
    serialString,
    request.profile_directory,
    request.certificate_fingerprint,
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
    if (request.exclusive && !recoverOriginalDisplays(displayID)) {
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
  if (request.exclusive) {
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
