/**
 * @file tests/unit/test_remote_microphone_diagnostics.cpp
 * @brief Test aggregate remote microphone diagnostics.
 */

#include "../tests_common.h"

#include <array>
#include <chrono>
#include <limits>
#include <src/remote_microphone_diagnostics.h>

namespace {
  using namespace std::chrono_literals;

  TEST(RemoteMicrophoneDiagnosticsTests, AggregatesModesSourcesLevelsAndTiming) {
    remote_microphone::detail::microphone_diagnostics_t diagnostics;
    const auto arrival = std::chrono::steady_clock::time_point {1s};
    const std::array<std::uint8_t, 1> mono {0x00};
    const std::array<std::uint8_t, 1> stereo {0x04};
    const std::array<std::int16_t, 5> pcm {0, 3, -4, 32767, -32768};

    diagnostics.record_received();
    diagnostics.record_accepted(mono, std::numeric_limits<std::uint32_t>::max() - 4, 10, arrival);
    diagnostics.record_accepted(stereo, 15, 11, arrival + 25ms);
    diagnostics.record_frame(remote_microphone::detail::microphone_frame_source_e::packet, pcm);
    diagnostics.record_frame(remote_microphone::detail::microphone_frame_source_e::plc, pcm);
    diagnostics.record_frame(remote_microphone::detail::microphone_frame_source_e::synthetic_zero, pcm);
    diagnostics.record_rejected(true);
    diagnostics.record_reanchor();
    diagnostics.record_jitter_overflow();
    diagnostics.record_skipped(3);
    diagnostics.record_sink_drop();
    diagnostics.record_schedule_gap(7ms);

    const auto totals = diagnostics.totals();
    EXPECT_EQ(totals.received, 1);
    EXPECT_EQ(totals.accepted, 2);
    EXPECT_EQ(totals.rejected, 1);
    EXPECT_EQ(totals.opus_mono, 1);
    EXPECT_EQ(totals.opus_stereo, 1);
    EXPECT_EQ(totals.packet_frames, 1);
    EXPECT_EQ(totals.plc_frames, 1);
    EXPECT_EQ(totals.synthetic_zero_frames, 1);
    EXPECT_EQ(totals.late_or_replayed, 1);
    EXPECT_EQ(totals.pcm_samples, pcm.size());
    EXPECT_EQ(totals.pcm_zero_samples, 1);
    EXPECT_EQ(totals.pcm_clipped_samples, 2);
    EXPECT_EQ(totals.pcm_peak, 32768);
    EXPECT_NEAR(totals.pcm_rms(), 20723.9868, 0.001);
    EXPECT_DOUBLE_EQ(totals.pcm_zero_fraction(), 0.2);
    EXPECT_DOUBLE_EQ(totals.pcm_clipped_fraction(), 0.4);
    EXPECT_EQ(totals.max_arrival_gap, 25ms);
    EXPECT_EQ(totals.max_client_timestamp_delta_ms, 20);
    EXPECT_EQ(totals.max_schedule_gap, 7ms);
  }

  TEST(RemoteMicrophoneDiagnosticsTests, IntervalResetPreservesTotalsAndTimingBaseline) {
    remote_microphone::detail::microphone_diagnostics_t diagnostics;
    const std::array<std::uint8_t, 1> mono {0x00};
    const auto arrival = std::chrono::steady_clock::time_point {1s};
    diagnostics.record_accepted(mono, 100, 1, arrival);
    EXPECT_EQ(diagnostics.take_interval().accepted, 1);
    EXPECT_EQ(diagnostics.take_interval().accepted, 0);

    diagnostics.record_accepted(mono, 120, 2, arrival + 20ms);
    const auto interval = diagnostics.take_interval();
    EXPECT_EQ(interval.accepted, 1);
    EXPECT_EQ(interval.max_arrival_gap, 20ms);
    EXPECT_EQ(interval.max_client_timestamp_delta_ms, 20);
    EXPECT_EQ(diagnostics.totals().accepted, 2);
  }

  TEST(RemoteMicrophoneDiagnosticsTests, ReanchorResetsForwardTimingBaseline) {
    remote_microphone::detail::microphone_diagnostics_t diagnostics;
    const std::array<std::uint8_t, 1> mono {0x00};
    const auto arrival = std::chrono::steady_clock::time_point {1s};
    diagnostics.record_accepted(mono, 100, 20, arrival);
    (void) diagnostics.take_interval();

    diagnostics.record_reanchor();
    diagnostics.record_accepted(mono, 500, 0, arrival + 1s);
    diagnostics.record_accepted(mono, 520, 1, arrival + 1020ms);

    const auto interval = diagnostics.take_interval();
    EXPECT_EQ(interval.reanchors, 1);
    EXPECT_EQ(interval.max_arrival_gap, 20ms);
    EXPECT_EQ(interval.max_client_timestamp_delta_ms, 20);
  }
}  // namespace
