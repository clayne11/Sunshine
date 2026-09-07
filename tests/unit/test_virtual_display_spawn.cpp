/**
 * @file tests/unit/test_virtual_display_spawn.cpp
 * @brief Verify the descriptor policy used when spawning vd_helper.
 */
#include "../tests_common.h"

#if defined(__APPLE__)

  #include "../../src/platform/macos/vd_spawn.h"

  #include <cerrno>
  #include <cstdio>
  #include <cstring>
  #include <signal.h>
  #include <string>
  #include <sys/select.h>
  #include <sys/socket.h>
  #include <sys/wait.h>
  #include <unistd.h>

extern char **environ;

TEST(VirtualDisplaySpawn, ClosesUnlistedPipeAndSocketDescriptors) {
  int inherited_pipe[2];
  int inherited_socket[2];
  int output_pipe[2];
  ASSERT_EQ(vd_make_pipe(inherited_pipe), 0) << std::strerror(errno);
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, inherited_socket), 0) << std::strerror(errno);
  for (int &descriptor : inherited_socket) {
    const int high_descriptor = fcntl(descriptor, F_DUPFD, 64);
    ASSERT_GE(high_descriptor, 64) << std::strerror(errno);
    close(descriptor);
    descriptor = high_descriptor;
  }
  for (int &descriptor : inherited_pipe) {
    const int high_descriptor = fcntl(descriptor, F_DUPFD, 64);
    ASSERT_GE(high_descriptor, 64) << std::strerror(errno);
    close(descriptor);
    descriptor = high_descriptor;
  }
  ASSERT_EQ(vd_make_pipe(output_pipe), 0) << std::strerror(errno);

  char pipe_fd[16];
  char socket_fd[16];
  std::snprintf(pipe_fd, sizeof(pipe_fd), "%d", inherited_pipe[0]);
  std::snprintf(socket_fd, sizeof(socket_fd), "%d", inherited_socket[0]);

  // A descriptor not named in file actions must be closed by
  // POSIX_SPAWN_CLOEXEC_DEFAULT. The shell redirection attempts below test
  // both a pipe and a socket without creating a display or contacting
  // WindowServer.
  const char *script =
    "if eval \"true <&$1\" 2>/dev/null; then exit 1; fi; "
    "if eval \"true <&$2\" 2>/dev/null; then exit 1; fi; "
    "printf passed";
  const char *child_argv[] = {"sh", "-c", script, "sh", pipe_fd, socket_fd, nullptr};

  pid_t child = 0;
  const int spawn_error = vd_spawn_with_cloexec(&child, "/bin/sh", output_pipe[1], output_pipe[0], const_cast<char *const *>(child_argv), environ);

  close(output_pipe[1]);
  close(inherited_pipe[0]);
  close(inherited_pipe[1]);
  close(inherited_socket[0]);
  close(inherited_socket[1]);

  ASSERT_EQ(spawn_error, 0) << std::strerror(spawn_error);
  int child_status = 0;
  ASSERT_EQ(waitpid(child, &child_status, 0), child);
  char output[32] = {0};
  const ssize_t bytes_read = read(output_pipe[0], output, sizeof(output) - 1);
  close(output_pipe[0]);
  ASSERT_TRUE(WIFEXITED(child_status));
  ASSERT_EQ(WEXITSTATUS(child_status), 0) << std::string(output, bytes_read > 0 ? static_cast<size_t>(bytes_read) : 0);
  ASSERT_GT(bytes_read, 0);
  EXPECT_EQ(std::string(output, static_cast<size_t>(bytes_read)), "passed");
}

TEST(VirtualDisplaySpawn, DetectsParentExitWithGetppid) {
  int pid_pipe[2];
  int event_pipe[2];
  int ready_pipe[2];
  ASSERT_EQ(vd_make_pipe(pid_pipe), 0) << std::strerror(errno);
  ASSERT_EQ(vd_make_pipe(event_pipe), 0) << std::strerror(errno);
  ASSERT_EQ(vd_make_pipe(ready_pipe), 0) << std::strerror(errno);

  const pid_t supervisor = fork();
  ASSERT_GE(supervisor, 0) << std::strerror(errno);
  if (supervisor == 0) {
    close(pid_pipe[0]);
    close(event_pipe[0]);

    const pid_t watched = fork();
    if (watched < 0) {
      _exit(1);
    }
    if (watched == 0) {
      close(pid_pipe[1]);
      close(ready_pipe[0]);
      const pid_t original_parent = getppid();
      const char ready = '1';
      if (write(ready_pipe[1], &ready, sizeof(ready)) != sizeof(ready)) {
        _exit(1);
      }
      close(ready_pipe[1]);
      while (original_parent > 1 && getppid() == original_parent) {
        usleep(1000);
      }
      const char marker[] = "parent-exited";
      write(event_pipe[1], marker, sizeof(marker) - 1);
      close(event_pipe[1]);
      _exit(0);
    }

    close(ready_pipe[1]);
    const ssize_t bytes_written = write(pid_pipe[1], &watched, sizeof(watched));
    close(pid_pipe[1]);
    char ready = 0;
    const ssize_t bytes_read = read(ready_pipe[0], &ready, sizeof(ready));
    close(ready_pipe[0]);
    close(event_pipe[1]);
    _exit(bytes_written == sizeof(watched) && bytes_read == sizeof(ready) ? 0 : 1);
  }

  close(pid_pipe[1]);
  close(event_pipe[1]);
  close(ready_pipe[0]);
  close(ready_pipe[1]);

  pid_t watched = 0;
  ASSERT_EQ(read(pid_pipe[0], &watched, sizeof(watched)), static_cast<ssize_t>(sizeof(watched)));
  close(pid_pipe[0]);

  int supervisor_status = 0;
  ASSERT_EQ(waitpid(supervisor, &supervisor_status, 0), supervisor);
  ASSERT_TRUE(WIFEXITED(supervisor_status));
  ASSERT_EQ(WEXITSTATUS(supervisor_status), 0);

  fd_set read_set;
  FD_ZERO(&read_set);
  FD_SET(event_pipe[0], &read_set);
  struct timeval timeout = {5, 0};
  const int ready = select(event_pipe[0] + 1, &read_set, nullptr, nullptr, &timeout);
  if (ready <= 0) {
    kill(watched, SIGTERM);
    close(event_pipe[0]);
    FAIL() << "watched process did not observe parent exit before timeout";
  }

  char marker[sizeof("parent-exited")] = {0};
  const ssize_t bytes_read = read(event_pipe[0], marker, sizeof(marker) - 1);
  close(event_pipe[0]);
  if (bytes_read != static_cast<ssize_t>(sizeof(marker) - 1)) {
    kill(watched, SIGTERM);
  }
  ASSERT_EQ(bytes_read, static_cast<ssize_t>(sizeof(marker) - 1));
  EXPECT_EQ(std::string(marker, static_cast<size_t>(bytes_read)), "parent-exited");
}

#else

TEST(VirtualDisplaySpawn, ClosesUnlistedPipeAndSocketDescriptors) {
  GTEST_SKIP() << "vd_helper descriptor policy is macOS-specific";
}

TEST(VirtualDisplaySpawn, DetectsParentExitWithGetppid) {
  GTEST_SKIP() << "vd_helper parent watchdog is macOS-specific";
}

#endif
