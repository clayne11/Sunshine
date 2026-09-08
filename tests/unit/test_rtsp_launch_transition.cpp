/**
 * @file tests/unit/test_rtsp_launch_transition.cpp
 * @brief Test RTSP launch and teardown coordination.
 */

// test includes
#include "../tests_common.h"

// standard includes
#include <atomic>
#include <chrono>
#include <future>
#include <memory>
#include <thread>

// local includes
#include <src/rtsp.h>

using namespace std::chrono_literals;

namespace rtsp_stream {
  bool should_force_virtual_display_cleanup(bool virtual_display_enabled, bool owner_released, int active_session_count);
}

namespace {
  constexpr std::uint32_t pending_session_id = 0xC0DE0001;

  /**
   * @brief Clear the test launch if an assertion exits the test early.
   */
  class pending_launch_cleanup_t {
  public:
    /**
     * @brief Clear the pending launch owned by this test.
     */
    ~pending_launch_cleanup_t() {
      rtsp_stream::launch_session_clear(pending_session_id);
    }
  };

  /**
   * @brief Make a launch session with the test identifier.
   * @return Launch state suitable for the RTSP pending queue.
   */
  std::shared_ptr<rtsp_stream::launch_session_t> make_launch_session() {
    auto session = std::make_shared<rtsp_stream::launch_session_t>();
    session->id = pending_session_id;
    return session;
  }
}  // namespace

TEST(RtspLaunchTransitionTests, TeardownCompletesBeforeLaunchObservesSessionState) {
  std::promise<void> teardown_locked;
  std::promise<void> finish_teardown;
  auto finish_teardown_signal = finish_teardown.get_future().share();
  std::atomic_bool launch_entered {false};

  std::jthread teardown {[&]() {
    rtsp_stream::launch_transition_guard_t transition {true};
    teardown_locked.set_value();
    finish_teardown_signal.wait();
  }};
  teardown_locked.get_future().wait();

  std::jthread launch {[&]() {
    rtsp_stream::launch_transition_guard_t transition {true};
    launch_entered = true;
  }};

  std::this_thread::sleep_for(20ms);
  EXPECT_FALSE(launch_entered);
  finish_teardown.set_value();
  teardown.join();
  launch.join();
  EXPECT_TRUE(launch_entered);
}

TEST(RtspLaunchTransitionTests, PendingLaunchIsPublishedBeforeDelayedTeardownContinues) {
  pending_launch_cleanup_t cleanup;
  std::promise<void> teardown_attempted;
  std::atomic_bool teardown_saw_pending {false};

  std::jthread teardown;
  {
    rtsp_stream::launch_transition_guard_t transition {true};
    teardown = std::jthread {[&]() {
      teardown_attempted.set_value();
      rtsp_stream::launch_transition_guard_t delayed_transition {true};
      teardown_saw_pending = rtsp_stream::launch_session_pending();
    }};
    teardown_attempted.get_future().wait();

    EXPECT_TRUE(rtsp_stream::launch_session_raise(make_launch_session()));
  }

  teardown.join();
  EXPECT_TRUE(teardown_saw_pending);
}

TEST(RtspLaunchTransitionTests, NestedCleanupUsesTheSameTransition) {
  rtsp_stream::launch_transition_guard_t outer {true};
  rtsp_stream::launch_transition_guard_t inner {true};
  SUCCEED();
}

TEST(RtspLaunchTransitionTests, DisabledCoordinationDoesNotWaitForVirtualDisplayTransition) {
  std::promise<void> entered;
  auto entered_signal = entered.get_future();
  std::jthread uncoordinated;
  {
    rtsp_stream::launch_transition_guard_t transition {true};
    uncoordinated = std::jthread {[&]() {
      rtsp_stream::launch_transition_guard_t disabled_transition {false};
      entered.set_value();
    }};
    EXPECT_EQ(entered_signal.wait_for(100ms), std::future_status::ready);
  }
}

TEST(RtspLaunchTransitionTests, RejectsASecondPendingLaunch) {
  pending_launch_cleanup_t cleanup;
  EXPECT_TRUE(rtsp_stream::launch_session_raise(make_launch_session()));
  EXPECT_FALSE(rtsp_stream::launch_session_raise(make_launch_session()));
  EXPECT_TRUE(rtsp_stream::launch_session_pending());
}

TEST(RtspLaunchTransitionTests, TimeoutReleasesOnlyAnUnusedInheritedDisplay) {
  EXPECT_TRUE(rtsp_stream::should_force_virtual_display_cleanup(true, false, 0));
  EXPECT_FALSE(rtsp_stream::should_force_virtual_display_cleanup(true, true, 0));
  EXPECT_FALSE(rtsp_stream::should_force_virtual_display_cleanup(true, false, 1));
  EXPECT_FALSE(rtsp_stream::should_force_virtual_display_cleanup(false, false, 0));
}
