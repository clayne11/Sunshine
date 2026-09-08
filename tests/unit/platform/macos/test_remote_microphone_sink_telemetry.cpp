/**
 * @file tests/unit/platform/macos/test_remote_microphone_sink_telemetry.cpp
 * @brief Tests for lock-free remote microphone sink telemetry.
 */

// test includes
#include "../../../tests_common.h"

// standard includes
#include <cstdint>

// local includes
#include <src/platform/macos/remote_microphone_sink.h>

/**
 * @brief Test callback, gap, render, and regressing timestamp accounting.
 */
TEST(RemoteMicrophoneSinkTelemetry, TracksCallbackGapAndRenderTotals) {
  platf::remote_microphone::detail::sink_telemetry_t telemetry;

  telemetry.record_callback(256, 1000);
  telemetry.record_callback(256, 2000);
  telemetry.record_callback(256, 1500);
  telemetry.record_callback(256, 3500);
  telemetry.record_render(500, 12);

  EXPECT_EQ(telemetry.callback_count.load(), 4U);
  EXPECT_EQ(telemetry.callback_requested_frames.load(), 1024U);
  EXPECT_EQ(telemetry.callback_read_frames.load(), 500U);
  EXPECT_EQ(telemetry.callback_underrun_frames.load(), 12U);
  EXPECT_EQ(telemetry.callback_max_gap_ticks.load(), 1500U);
}

/**
 * @brief Test format, exclusion mute, and ring loss accounting.
 */
TEST(RemoteMicrophoneSinkTelemetry, TracksFormatMuteAndRingLosses) {
  platf::remote_microphone::detail::sink_telemetry_t telemetry;

  telemetry.record_format_anomaly();
  telemetry.record_exclusion_mute(128);
  telemetry.record_ring_write(900, 60);
  telemetry.record_input_rejection(32);

  EXPECT_EQ(telemetry.format_anomalies.load(), 1U);
  EXPECT_EQ(telemetry.exclusion_muted_frames.load(), 128U);
  EXPECT_EQ(telemetry.ring_written_samples.load(), 900U);
  EXPECT_EQ(telemetry.ring_dropped_samples.load(), 60U);
  EXPECT_EQ(telemetry.input_rejected_samples.load(), 32U);
}
