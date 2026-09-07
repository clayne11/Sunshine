/**
 * @file src/platform/macos/vd_spawn.h
 * @brief File-descriptor policy for the virtual-display helper subprocess.
 */
#pragma once

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdbool.h>
#include <unistd.h>

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
 * @param argv Null-terminated argument vector.
 * @param envp Null-terminated environment vector.
 * @return Zero on success, otherwise an errno-style error code.
 */
static inline int vd_spawn_with_cloexec(pid_t *pid, const char *path, int child_stdout_fd, int child_close_fd, char *const argv[], char *const envp[]) {
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
  if (error == 0 && child_close_fd != STDIN_FILENO && child_close_fd != STDOUT_FILENO &&
      child_close_fd != STDERR_FILENO) {
    error = posix_spawn_file_actions_addclose(&actions, child_close_fd);
  }
  if (error == 0 && child_stdout_fd != STDIN_FILENO && child_stdout_fd != STDOUT_FILENO &&
      child_stdout_fd != STDERR_FILENO && child_stdout_fd != child_close_fd) {
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
    error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
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
