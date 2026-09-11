/**
 * @file src/platform/macos/vd_spawn.h
 * @brief File-descriptor policy for the virtual-display helper subprocess.
 */
#pragma once

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/** @brief Sunshine-to-guardian startup deadline in milliseconds. */
#define VD_CONTROLLER_STARTUP_TIMEOUT_MS 20000ULL
/** @brief Guardian-to-holder startup deadline in milliseconds. */
#define VD_GUARDIAN_STARTUP_TIMEOUT_MS 18000ULL
/** @brief Maximum guardian polling interval while supervising its parent and holder. */
#define VD_GUARDIAN_STARTUP_SLICE_MS 100ULL

/** @brief Incremental state for the helper's one-line display-ID protocol. */
typedef struct vd_display_id_line_t {
  char buffer[64];  ///< Bounded decimal display ID and newline.
  size_t used;  ///< Bytes accumulated in buffer.
} vd_display_id_line_t;

/** @brief Result of adding bytes to a display-ID protocol line. */
typedef enum vd_display_id_line_result_t {
  VD_DISPLAY_ID_LINE_MORE,  ///< A complete newline-terminated line has not arrived.
  VD_DISPLAY_ID_LINE_READY,  ///< A valid display ID line was parsed.
  VD_DISPLAY_ID_LINE_ERROR,  ///< The line was malformed or exceeded its bound.
} vd_display_id_line_result_t;

/**
 * @brief Return a monotonic timestamp in milliseconds.
 * @return Milliseconds since an arbitrary monotonic epoch, or zero on failure.
 */
static inline uint64_t vd_monotonic_milliseconds(void) {
  struct timespec now = {};
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return (uint64_t) now.tv_sec * 1000ULL + (uint64_t) now.tv_nsec / 1000000ULL;
}

/**
 * @brief Bound one wait interval by an absolute startup deadline.
 * @param now_ms Current monotonic time in milliseconds.
 * @param deadline_ms Absolute monotonic deadline in milliseconds.
 * @param maximum_ms Maximum desired wait interval in milliseconds.
 * @param timeout Receives a timeval suitable for select().
 * @return True when time remains before the deadline.
 */
static inline bool vd_startup_wait_interval(uint64_t now_ms, uint64_t deadline_ms, uint64_t maximum_ms, struct timeval *timeout) {
  if (!timeout || now_ms == 0 || now_ms >= deadline_ms) {
    return false;
  }
  uint64_t remaining_ms = deadline_ms - now_ms;
  if (maximum_ms > 0 && remaining_ms > maximum_ms) {
    remaining_ms = maximum_ms;
  }
  timeout->tv_sec = (time_t) (remaining_ms / 1000ULL);
  timeout->tv_usec = (suseconds_t) ((remaining_ms % 1000ULL) * 1000ULL);
  return true;
}

/**
 * @brief Append bytes and parse one bounded newline-terminated display ID.
 * @param line Mutable protocol buffer.
 * @param bytes Newly read bytes.
 * @param byte_count Number of newly read bytes.
 * @param display_id Receives the parsed ID, including zero for helper failure.
 * @return Whether more bytes are needed, the ID is ready, or the line is invalid.
 */
static inline vd_display_id_line_result_t vd_display_id_line_append(vd_display_id_line_t *line, const char *bytes, size_t byte_count, uint32_t *display_id) {
  if (!line || !bytes || !display_id || byte_count == 0 || line->used >= sizeof(line->buffer) || byte_count > sizeof(line->buffer) - line->used - 1) {
    return VD_DISPLAY_ID_LINE_ERROR;
  }

  memcpy(line->buffer + line->used, bytes, byte_count);
  line->used += byte_count;
  line->buffer[line->used] = '\0';
  char *newline = (char *) memchr(line->buffer, '\n', line->used);
  if (!newline) {
    return VD_DISPLAY_ID_LINE_MORE;
  }
  if (newline != line->buffer + line->used - 1) {
    return VD_DISPLAY_ID_LINE_ERROR;
  }

  *newline = '\0';
  char *end = NULL;
  errno = 0;
  const unsigned long parsed = strtoul(line->buffer, &end, 10);
  if (errno != 0 || end == line->buffer || end != newline || parsed > UINT32_MAX) {
    return VD_DISPLAY_ID_LINE_ERROR;
  }
  *display_id = (uint32_t) parsed;
  return VD_DISPLAY_ID_LINE_READY;
}

/**
 * @brief Move a descriptor above stdin, stdout, and stderr when necessary.
 *
 * @param descriptor Descriptor to move.
 * @return The original descriptor when already above stdio, the moved
 * descriptor on success, or -1 on failure.
 */
static inline int vd_move_fd_above_stdio(int descriptor) {
  if (descriptor > STDERR_FILENO) {
    return descriptor;
  }

  int moved = fcntl(descriptor, F_DUPFD, STDERR_FILENO + 1);
  if (moved >= 0) {
    close(descriptor);
  }
  return moved;
}

/**
 * @brief Create a pipe whose descriptors cannot overlap standard streams.
 *
 * @param pipefd Receives the read and write descriptors.
 * @return Zero on success, otherwise an errno-style error code.
 */
static inline int vd_make_pipe(int pipefd[2]) {
  if (pipe(pipefd) != 0) {
    return errno;
  }

  for (int i = 0; i < 2; i++) {
    const int original = pipefd[i];
    const int moved = vd_move_fd_above_stdio(original);
    if (moved < 0) {
      const int error = errno;
      close(pipefd[0]);
      close(pipefd[1]);
      return error;
    }
    pipefd[i] = moved;
  }
  return 0;
}

/**
 * @brief Spawn a helper with only its standard streams explicitly inherited.
 *
 * @param pid Receives the spawned process ID.
 * @param path Executable path.
 * @param child_stdout_fd Descriptor to connect to the child's stdout.
 * @param child_close_fd Descriptor to close in the child after setup.
 * @param create_process_group Whether the child should lead a new process group.
 * @param argv Null-terminated argument vector.
 * @param envp Null-terminated environment vector.
 * @return Zero on success, otherwise an errno-style error code.
 */
static inline int vd_spawn_with_cloexec(pid_t *pid, const char *path, int child_stdout_fd, int child_close_fd, bool create_process_group, char *const argv[], char *const envp[]) {
  posix_spawn_file_actions_t actions;
  int error = posix_spawn_file_actions_init(&actions);
  if (error != 0) {
    return error;
  }

  error = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO);
  if (error == 0) {
    error = posix_spawn_file_actions_adddup2(&actions, child_stdout_fd, STDOUT_FILENO);
  }
  if (error == 0) {
    error = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);
  }
  if (error == 0 && child_close_fd != STDIN_FILENO && child_close_fd != STDOUT_FILENO && child_close_fd != STDERR_FILENO) {
    error = posix_spawn_file_actions_addclose(&actions, child_close_fd);
  }
  if (error == 0 && child_stdout_fd != STDIN_FILENO && child_stdout_fd != STDOUT_FILENO && child_stdout_fd != STDERR_FILENO && child_stdout_fd != child_close_fd) {
    error = posix_spawn_file_actions_addclose(&actions, child_stdout_fd);
  }
  if (error != 0) {
    posix_spawn_file_actions_destroy(&actions);
    return error;
  }

  posix_spawnattr_t attributes;
  error = posix_spawnattr_init(&attributes);
  const bool attributes_initialized = error == 0;
  if (error == 0) {
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (create_process_group) {
      flags |= POSIX_SPAWN_SETPGROUP;
      error = posix_spawnattr_setpgroup(&attributes, 0);
    }
    if (error == 0) {
      error = posix_spawnattr_setflags(&attributes, flags);
    }
  }
  if (error != 0) {
    if (attributes_initialized) {
      posix_spawnattr_destroy(&attributes);
    }
    posix_spawn_file_actions_destroy(&actions);
    return error;
  }

  error = posix_spawn(pid, path, &actions, &attributes, argv, envp);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  return error;
}

/**
 * @brief Reap a child if it has exited without blocking.
 *
 * @param pid Child process identifier.
 * @param status Receives the wait status when the child exited.
 * @return One when reaped or already absent, zero while running, or -1 on error.
 */
static inline int vd_reap_child_if_exited(pid_t pid, int *status) {
  if (pid <= 0) {
    errno = EINVAL;
    return -1;
  }

  pid_t result;
  do {
    result = waitpid(pid, status, WNOHANG);
  } while (result < 0 && errno == EINTR);

  if (result == pid || (result < 0 && errno == ECHILD)) {
    return 1;
  }
  if (result == 0) {
    return 0;
  }
  return -1;
}

/**
 * @brief Stop and reap a child process within a bounded grace period.
 *
 * @param pid Child process identifier.
 * @param graceful_attempts Number of nonblocking waits after SIGTERM.
 * @param forced_attempts Number of nonblocking waits after SIGKILL.
 * @param interval Microseconds between nonblocking waits.
 * @param status Receives the final wait status when available.
 * @return True when the child is known to be reaped or already absent.
 */
static inline bool vd_terminate_and_reap(pid_t pid, unsigned int graceful_attempts, unsigned int forced_attempts, useconds_t interval, int *status) {
  if (pid <= 0) {
    errno = EINVAL;
    return false;
  }

  int local_status = 0;
  if (!status) {
    status = &local_status;
  }

  int state = vd_reap_child_if_exited(pid, status);
  if (state == 1) {
    return true;
  }
  if (state < 0) {
    return false;
  }

  if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
    return false;
  }
  for (unsigned int attempt = 0; attempt < graceful_attempts; ++attempt) {
    state = vd_reap_child_if_exited(pid, status);
    if (state == 1) {
      return true;
    }
    if (state < 0) {
      return false;
    }
    usleep(interval);
  }

  if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
    return false;
  }

  for (unsigned int attempt = 0; attempt < forced_attempts; ++attempt) {
    state = vd_reap_child_if_exited(pid, status);
    if (state == 1) {
      return true;
    }
    if (state < 0) {
      return false;
    }
    usleep(interval);
  }
  return false;
}
