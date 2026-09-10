/**
 * @file tests/unit/test_remote_microphone_playout.cpp
 * @brief Regression tests for bounded remote microphone jitter playout.
 */

// test includes
#include "../tests_common.h"

// standard includes
#include <cstdint>
#include <map>
#include <optional>
#include <vector>

// local includes
#include <src/remote_microphone.h>

namespace {
  /**
   * @brief Add one synthetic admitted payload and trim the production jitter queue.
   *
   * @param queue Ordered payloads representing the receiver's jitter queue.
   * @param next_playout_sequence Sequence expected by the playout clock.
   * @param sequence Extended sequence to admit.
   * @return Result of the production queue trim operation.
   */
  remote_microphone::detail::jitter_trim_result_t add_packet(
    remote_microphone::detail::jitter_packet_queue_t &queue,
    std::optional<std::int64_t> &next_playout_sequence,
    std::int64_t sequence
  ) {
    queue.emplace(sequence, std::vector<std::uint8_t> {1});
    return remote_microphone::detail::trim_jitter_queue(queue, 4, next_playout_sequence);
  }
}  // namespace

TEST(RemoteMicrophonePlayoutTests, DropsOldestBurstFramesAndContinuesSteadyPlayout) {
  remote_microphone::detail::jitter_packet_queue_t queue;
  std::optional<std::int64_t> next_playout_sequence = 0;
  std::uint64_t skipped_frames = 0;
  std::uint64_t overflow_count = 0;

  for (std::int64_t sequence = 0; sequence < 16; ++sequence) {
    const auto result = add_packet(queue, next_playout_sequence, sequence);
    skipped_frames += result.skipped_frames;
    overflow_count += result.overflow;
  }

  ASSERT_EQ(queue.size(), 4);
  EXPECT_EQ(next_playout_sequence, 12);
  EXPECT_EQ(skipped_frames, 12);
  EXPECT_EQ(overflow_count, 12);
  EXPECT_EQ(queue.begin()->first, 12);
  EXPECT_EQ(queue.rbegin()->first, 15);

  for (std::int64_t sequence = 16; sequence < 26; ++sequence) {
    ASSERT_TRUE(next_playout_sequence);
    const auto packet = queue.find(*next_playout_sequence);
    ASSERT_NE(packet, queue.end());
    queue.erase(packet);
    ++*next_playout_sequence;

    const auto result = add_packet(queue, next_playout_sequence, sequence);
    EXPECT_FALSE(result.overflow);
  }

  ASSERT_EQ(queue.size(), 4);
  EXPECT_EQ(next_playout_sequence, 22);
  EXPECT_EQ(queue.begin()->first, 22);
  EXPECT_EQ(queue.rbegin()->first, 25);
}

TEST(RemoteMicrophonePlayoutTests, PreservesOrderingAndCursorWhenQueueFits) {
  remote_microphone::detail::jitter_packet_queue_t queue;
  queue.emplace(20, std::vector<std::uint8_t> {1});
  queue.emplace(18, std::vector<std::uint8_t> {1});
  queue.emplace(19, std::vector<std::uint8_t> {1});
  queue.emplace(17, std::vector<std::uint8_t> {1});
  std::optional<std::int64_t> next_playout_sequence = 18;

  const auto result = remote_microphone::detail::trim_jitter_queue(queue, 4, next_playout_sequence);

  EXPECT_FALSE(result.overflow);
  EXPECT_EQ(result.skipped_frames, 0);
  ASSERT_EQ(queue.size(), 4);
  EXPECT_EQ(queue.begin()->first, 17);
  EXPECT_EQ(queue.rbegin()->first, 20);
  ASSERT_TRUE(next_playout_sequence);
  EXPECT_EQ(*next_playout_sequence, 18);
}

TEST(RemoteMicrophonePlayoutTests, NeverRewindsAnAdvancedPlayoutCursor) {
  remote_microphone::detail::jitter_packet_queue_t queue;
  for (std::int64_t sequence = 100; sequence < 105; ++sequence) {
    queue.emplace(sequence, std::vector<std::uint8_t> {1});
  }
  std::optional<std::int64_t> next_playout_sequence = 102;

  const auto result = remote_microphone::detail::trim_jitter_queue(queue, 4, next_playout_sequence);

  EXPECT_TRUE(result.overflow);
  EXPECT_EQ(result.skipped_frames, 0);
  ASSERT_EQ(queue.size(), 4);
  EXPECT_EQ(queue.begin()->first, 101);
  EXPECT_EQ(queue.rbegin()->first, 104);
  ASSERT_TRUE(next_playout_sequence);
  EXPECT_EQ(*next_playout_sequence, 102);
}

TEST(RemoteMicrophonePlayoutTests, UninitializedCursorSurvivesZeroCapacityTrim) {
  remote_microphone::detail::jitter_packet_queue_t queue;
  queue.emplace(1, std::vector<std::uint8_t> {1});
  queue.emplace(2, std::vector<std::uint8_t> {1});
  std::optional<std::int64_t> next_playout_sequence;

  const auto result = remote_microphone::detail::trim_jitter_queue(queue, 0, next_playout_sequence);

  EXPECT_TRUE(result.overflow);
  EXPECT_EQ(result.skipped_frames, 0);
  EXPECT_TRUE(queue.empty());
  EXPECT_FALSE(next_playout_sequence);
}

TEST(RemoteMicrophonePlayoutTests, PreservesMissingPacketDeadlineWithoutOverflow) {
  remote_microphone::detail::jitter_packet_queue_t queue;
  queue.emplace(11, std::vector<std::uint8_t> {1});
  std::optional<std::int64_t> next_playout_sequence = 10;

  const auto result = remote_microphone::detail::trim_jitter_queue(queue, 4, next_playout_sequence);

  EXPECT_FALSE(result.overflow);
  EXPECT_EQ(result.skipped_frames, 0);
  EXPECT_EQ(next_playout_sequence, 10);
  EXPECT_EQ(queue.begin()->first, 11);
}
