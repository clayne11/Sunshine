/**
 * @file src/platform/macos/virtual_display.m
 * @brief CGVirtualDisplay-based virtual display management for macOS 14+.
 *
 * Spawns a helper subprocess (vd_helper) to create and hold the virtual display.
 * This avoids process-level state in Sunshine (TCC, frameworks, etc.) that prevents
 * CGVirtualDisplay from registering with WindowServer when created in-process.
 *
 * This file is compiled with ARC (-fobjc-arc). See macos.cmake.
 */
#include "virtual_display.h"

#include "vd_spawn.h"

#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

/** @brief Process environment passed to the helper subprocess. */
extern char **environ;

// State protected by mutex
static pthread_mutex_t vd_mutex = PTHREAD_MUTEX_INITIALIZER;
static pid_t vd_helper_pid = 0;
static uint32_t vd_display_id = 0;
static bool vd_requested = false;  ///< A successful request remains active until explicit destruction.

/**
 * @brief Test whether WindowServer has made a display usable to capture.
 * @param displayID Display identifier to inspect.
 * @return YES when the display is both online and active.
 */
static BOOL displayIsReady(CGDirectDisplayID displayID) {
  return CGDisplayIsOnline(displayID) && CGDisplayIsActive(displayID);
}

/**
 * @brief Wait for a display to become online and active.
 * @param displayID Display identifier to inspect.
 * @return YES when the display becomes ready before the bounded deadline.
 */
static BOOL waitForDisplayReady(CGDirectDisplayID displayID) {
  static const unsigned int attempts = 40;
  static const useconds_t interval = 50000;
  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    if (displayIsReady(displayID)) {
      return YES;
    }
    usleep(interval);
  }
  return displayIsReady(displayID);
}

/**
 * @brief Reap a child without blocking indefinitely.
 * @param pid Child process identifier.
 * @param attempts Number of nonblocking wait attempts.
 * @return YES when the child was reaped or was already gone.
 */
static BOOL reapHelper(pid_t pid, unsigned int attempts) {
  static const useconds_t interval = 50000;
  int status = 0;
  for (unsigned int attempt = 0; attempt < attempts; ++attempt) {
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == pid) {
      return YES;
    }
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return errno == ECHILD;
    }
    usleep(interval);
  }
  return NO;
}

/**
 * @brief Stop and boundedly reap the helper process.
 * @param pid Child process identifier.
 * @return YES when the child was reaped or was already gone.
 */
static BOOL stopHelper(pid_t pid) {
  static const unsigned int gracefulAttempts = 300;
  static const unsigned int forcedAttempts = 40;
  if (pid <= 0) {
    return YES;
  }
  if (kill(pid, SIGTERM) < 0 && errno != ESRCH) {
    NSLog(@"[Sunshine] Failed to stop vd_helper pid=%d: %s", pid, strerror(errno));
  }
  if (reapHelper(pid, gracefulAttempts)) {
    return YES;
  }
  NSLog(@"[Sunshine] vd_helper pid=%d did not exit after SIGTERM; sending SIGKILL", pid);
  if (kill(pid, SIGKILL) < 0 && errno != ESRCH) {
    NSLog(@"[Sunshine] Failed to kill vd_helper pid=%d: %s", pid, strerror(errno));
  }
  return reapHelper(pid, forcedAttempts);
}

/**
 * @brief Keep a helper in controller state when bounded cleanup did not reap it.
 * @param pid Surviving helper process identifier.
 * @param displayID Last known display identifier, or zero when startup was incomplete.
 *
 * The request flag is deliberately set so capture fails closed until a later
 * destroy or create call can retry cleanup.
 */
static void retainUnreapedHelper(pid_t pid, uint32_t displayID) {
  vd_helper_pid = pid;
  vd_display_id = displayID;
  vd_requested = true;
}

/**
 * @brief Clear helper state after bounded cleanup succeeds.
 * @param requested Whether an earlier successful request must remain active.
 */
static void clearStoppedHelperState(bool requested) {
  vd_helper_pid = 0;
  vd_display_id = 0;
  vd_requested = requested;
}

/**
 * @brief Notice when the helper has exited without an explicit destroy call.
 *
 * @remarks The caller must hold vd_mutex.
 */
static void refreshHelperState(void) {
  if (vd_helper_pid <= 0) {
    return;
  }
  int status = 0;
  pid_t result = waitpid(vd_helper_pid, &status, WNOHANG);
  if (result == vd_helper_pid || (result < 0 && (errno == ECHILD || errno == ESRCH))) {
    NSLog(@"[Sunshine] vd_helper pid=%d exited; clearing virtual display state", vd_helper_pid);
    vd_helper_pid = 0;
    vd_display_id = 0;
  }
}

/**
 * @brief Get the path to the vd_helper binary beside the Sunshine executable.
 * @return The helper path, or nil when the executable path cannot be resolved.
 */
static NSString *helperPath(void) {
  NSString *mainExe = [[NSBundle mainBundle] executablePath];
  if (!mainExe) {
    // Fallback: use /proc/self or _NSGetExecutablePath
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
      mainExe = [[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath];
    }
  }
  if (!mainExe) {
    return nil;
  }
  NSString *dir = [mainExe stringByDeletingLastPathComponent];
  return [dir stringByAppendingPathComponent:@"vd_helper"];
}

uint32_t virtual_display_create(int width, int height, int fps, bool exclusive) {
  pthread_mutex_lock(&vd_mutex);
  refreshHelperState();

  // Keep a previous successful request fail-closed if replacing its helper fails.
  // A first unsuccessful request must not make capture reject the physical display.
  const bool had_request = vd_requested;

  // Destroy existing display first
  if (vd_helper_pid > 0) {
    NSLog(@"[Sunshine] Killing existing vd_helper (pid=%d, display=%u) before creating new one", vd_helper_pid, vd_display_id);
    if (!stopHelper(vd_helper_pid)) {
      NSLog(@"[Sunshine] Could not reap existing vd_helper pid=%d", vd_helper_pid);
      retainUnreapedHelper(vd_helper_pid, vd_display_id);
      pthread_mutex_unlock(&vd_mutex);
      return 0;
    }
    clearStoppedHelperState(had_request);
  }

  NSString *helper = helperPath();
  if (!helper) {
    NSLog(@"[Sunshine] Could not determine vd_helper path");
    vd_requested = had_request;
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
    NSLog(@"[Sunshine] vd_helper not found at: %@", helper);
    vd_requested = had_request;
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  NSLog(@"[Sunshine] Spawning vd_helper: %@ %d %d %d (%@)", helper, width, height, fps, exclusive ? @"exclusive" : @"extend");

  // Set up pipe for reading displayID from child's stdout
  int pipefd[2];
  int pipe_err = vd_make_pipe(pipefd);
  if (pipe_err != 0) {
    NSLog(@"[Sunshine] pipe() failed: %s", strerror(pipe_err));
    vd_requested = had_request;
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  // Build argv
  char widthStr[16], heightStr[16], fpsStr[16];
  snprintf(widthStr, sizeof(widthStr), "%d", width);
  snprintf(heightStr, sizeof(heightStr), "%d", height);
  snprintf(fpsStr, sizeof(fpsStr), "%d", fps);

  const char *modeStr = exclusive ? "exclusive" : "extend";
  const char *argv[] = {
    [helper fileSystemRepresentation],
    widthStr,
    heightStr,
    fpsStr,
    modeStr,
    NULL
  };

  pid_t pid;
  int err = vd_spawn_with_cloexec(&pid, argv[0], pipefd[1], pipefd[0], true, (char *const *) argv, environ);

  // Close write end in parent
  close(pipefd[1]);

  if (err != 0) {
    NSLog(@"[Sunshine] posix_spawn failed: %s", strerror(err));
    close(pipefd[0]);
    vd_requested = had_request;
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  NSLog(@"[Sunshine] vd_helper spawned (pid=%d)", pid);

  // Read displayID from child's stdout (with timeout)
  char buf[64] = {0};
  ssize_t n = 0;
  fd_set readfds;
  struct timeval tv;
  tv.tv_sec = 10;
  tv.tv_usec = 0;
  FD_ZERO(&readfds);
  FD_SET(pipefd[0], &readfds);

  int sel = select(pipefd[0] + 1, &readfds, NULL, NULL, &tv);
  if (sel > 0) {
    n = read(pipefd[0], buf, sizeof(buf) - 1);
  }
  close(pipefd[0]);

  if (n <= 0) {
    NSLog(@"[Sunshine] vd_helper produced no output, killing");
    if (!stopHelper(pid)) {
      NSLog(@"[Sunshine] Could not reap vd_helper pid=%d after failed startup", pid);
      retainUnreapedHelper(pid, 0);
    } else {
      clearStoppedHelperState(had_request);
    }
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  char *end = NULL;
  errno = 0;
  const unsigned long parsedID = strtoul(buf, &end, 10);
  const bool validID = errno == 0 && end != buf && parsedID <= UINT32_MAX && (*end == '\0' || *end == '\n');
  const uint32_t displayID = validID ? (uint32_t) parsedID : 0;
  if (!validID || displayID == 0) {
    NSLog(@"[Sunshine] vd_helper returned displayID=0, killing");
    if (!stopHelper(pid)) {
      NSLog(@"[Sunshine] Could not reap vd_helper pid=%d after invalid display ID", pid);
      retainUnreapedHelper(pid, displayID);
    } else {
      clearStoppedHelperState(had_request);
    }
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  if (!waitForDisplayReady(displayID)) {
    NSLog(@"[Sunshine] Virtual display %u did not become online and active", displayID);
    if (!stopHelper(pid)) {
      NSLog(@"[Sunshine] Could not reap vd_helper pid=%d after readiness failure", pid);
      retainUnreapedHelper(pid, displayID);
    } else {
      clearStoppedHelperState(had_request);
    }
    pthread_mutex_unlock(&vd_mutex);
    return 0;
  }

  vd_helper_pid = pid;
  vd_display_id = displayID;
  vd_requested = true;

  NSLog(@"[Sunshine] Virtual display %u created via vd_helper (pid=%d)", displayID, pid);

  // Verify from parent process too
  CGDirectDisplayID activeDisplays[32];
  uint32_t displayCount = 0;
  if (CGGetActiveDisplayList(32, activeDisplays, &displayCount) == kCGErrorSuccess) {
    BOOL found = NO;
    for (uint32_t i = 0; i < displayCount; i++) {
      if (activeDisplays[i] == displayID) {
        found = YES;
        break;
      }
    }
    NSLog(@"[Sunshine] Parent sees display %u: %@ in CGGetActiveDisplayList (%u total)", displayID, found ? @"FOUND" : @"NOT found", displayCount);
  }

  pthread_mutex_unlock(&vd_mutex);
  return displayID;
}

void virtual_display_destroy(void) {
  pthread_mutex_lock(&vd_mutex);

  if (vd_helper_pid > 0) {
    uint32_t old_id = vd_display_id;
    pid_t old_pid = vd_helper_pid;
    NSLog(@"[Sunshine] Destroying virtual display %u (killing vd_helper pid=%d)", old_id, old_pid);
    if (!stopHelper(old_pid)) {
      NSLog(@"[Sunshine] Could not reap vd_helper pid=%d during destroy", old_pid);
      retainUnreapedHelper(old_pid, old_id);
      pthread_mutex_unlock(&vd_mutex);
      return;
    }
    clearStoppedHelperState(false);
    NSLog(@"[Sunshine] Destroyed virtual display %u", old_id);
  } else {
    vd_requested = false;
  }

  pthread_mutex_unlock(&vd_mutex);
}

uint32_t virtual_display_get_id(void) {
  pthread_mutex_lock(&vd_mutex);
  refreshHelperState();
  uint32_t result = vd_display_id;
  pthread_mutex_unlock(&vd_mutex);
  return result;
}

bool virtual_display_is_requested(void) {
  pthread_mutex_lock(&vd_mutex);
  refreshHelperState();
  bool result = vd_requested;
  pthread_mutex_unlock(&vd_mutex);
  return result;
}

void virtual_display_get_state(virtual_display_state_t *state) {
  if (!state) {
    return;
  }

  pthread_mutex_lock(&vd_mutex);
  refreshHelperState();
  state->display_id = vd_display_id;
  state->requested = vd_requested;
  pthread_mutex_unlock(&vd_mutex);
}
