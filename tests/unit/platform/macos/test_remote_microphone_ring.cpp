/**
 * @file tests/unit/platform/macos/test_remote_microphone_ring.cpp
 * @brief Tests for the bounded remote microphone PCM ring.
 */

// test includes
#include "../../../tests_common.h"

// standard includes
#include <array>
#include <cstdint>
#include <vector>

// local includes
#include <src/platform/macos/remote_microphone_ring.h>

namespace {
  using platf::remote_microphone::detail::pcm_ring_t;
}

/**
 * @brief Test mono-to-stereo conversion and FIFO order.
 */
TEST(RemoteMicrophoneRing, ConvertsMonoToStereoInOrder) {
  pcm_ring_t ring;
  ASSERT_TRUE(ring.valid());

  const std::array<std::int16_t, 3> input {-32768, 0, 16384};
  std::array<float, 6> output {};
  ASSERT_TRUE(ring.write(input));
  ASSERT_EQ(ring.read_interleaved(output.data(), static_cast<std::uint32_t>(input.size())), static_cast<std::uint32_t>(input.size()));

  EXPECT_FLOAT_EQ(output[0], -1.0f);
  EXPECT_FLOAT_EQ(output[1], -1.0f);
  EXPECT_FLOAT_EQ(output[2], 0.0f);
  EXPECT_FLOAT_EQ(output[3], 0.0f);
  EXPECT_FLOAT_EQ(output[4], 0.5f);
  EXPECT_FLOAT_EQ(output[5], 0.5f);
}

/**
 * @brief Test that an empty ring reports underflow without producing frames.
 */
TEST(RemoteMicrophoneRing, EmptyReadDoesNotProduceFrames) {
  pcm_ring_t ring;
  std::array<float, 4> output {1.0f, 1.0f, 1.0f, 1.0f};

  EXPECT_EQ(ring.read_interleaved(output.data(), 2), 0U);
  EXPECT_FLOAT_EQ(output[0], 1.0f);
  EXPECT_FLOAT_EQ(output[1], 1.0f);
  EXPECT_FLOAT_EQ(output[2], 1.0f);
  EXPECT_FLOAT_EQ(output[3], 1.0f);
}

/**
 * @brief Test that a full ring rejects new input instead of growing.
 */
TEST(RemoteMicrophoneRing, FullRingBoundsQueuedAudio) {
  pcm_ring_t ring;
  const std::vector<std::int16_t> queued(pcm_ring_t::capacity_frames, 1000);
  const std::array<std::int16_t, 1> extra {2000};
  std::array<float, 2> output {};

  ASSERT_TRUE(ring.write(queued));
  EXPECT_FALSE(ring.write(extra));
  ASSERT_EQ(ring.read_interleaved(output.data(), 1), 1U);
  EXPECT_FLOAT_EQ(output[0], 1000.0f / 32768.0f);
  EXPECT_FLOAT_EQ(output[1], 1000.0f / 32768.0f);
}

/**
 * @brief Test that muting the output discards frames queued before the mute.
 */
TEST(RemoteMicrophoneRing, DiscardClearsQueuedAudio) {
  pcm_ring_t ring;
  const std::array<std::int16_t, 2> input {1000, 2000};
  std::array<float, 4> output {1.0f, 1.0f, 1.0f, 1.0f};

  ASSERT_TRUE(ring.write(input));
  ring.discard();

  EXPECT_EQ(ring.read_interleaved(output.data(), 2), 0U);
  EXPECT_FLOAT_EQ(output[0], 1.0f);
  EXPECT_FLOAT_EQ(output[1], 1.0f);
  EXPECT_FLOAT_EQ(output[2], 1.0f);
  EXPECT_FLOAT_EQ(output[3], 1.0f);
}
