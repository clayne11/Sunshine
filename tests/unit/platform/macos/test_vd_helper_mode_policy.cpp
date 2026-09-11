/**
 * @file tests/unit/platform/macos/test_vd_helper_mode_policy.cpp
 * @brief Unit tests for virtual-display mode observation policy.
 */
#include "src/platform/macos/vd_helper_mode_policy.h"

#include <gtest/gtest.h>

namespace {
  /**
   * @brief Build a display mode for observer-policy tests.
   * @param logical_width Logical mode width.
   * @param logical_height Logical mode height.
   * @param pixel_width Backing pixel width.
   * @param pixel_height Backing pixel height.
   * @param refresh_rate Observed refresh rate.
   * @param hidpi Whether the mode uses HiDPI scaling.
   * @return Complete display mode snapshot.
   */
  macos_display_mode_t mode(uint32_t logical_width, uint32_t logical_height, uint32_t pixel_width, uint32_t pixel_height, double refresh_rate, bool hidpi) {
    return macos_display_mode_t {logical_width, logical_height, pixel_width, pixel_height, refresh_rate, hidpi};
  }
}  // namespace

TEST(VirtualDisplayModePolicy, SavesEachMappingTransitionIncludingReturnToBaseline) {
  vd_helper_mode_tracker_t tracker {};
  const auto baseline = mode(2420, 1668, 2420, 1668, 30.0, false);
  const auto scaled = mode(1210, 834, 2420, 1668, 30.0, true);

  EXPECT_FALSE(vd_helper_mode_tracker_observe(&tracker, &baseline, true));
  EXPECT_FALSE(tracker.has_dirty_mode);

  EXPECT_TRUE(vd_helper_mode_tracker_observe(&tracker, &scaled, true));
  ASSERT_TRUE(tracker.has_dirty_mode);
  EXPECT_EQ(tracker.dirty_mode.logical_width, 1210U);
  vd_helper_mode_tracker_mark_saved(&tracker);
  EXPECT_FALSE(tracker.has_dirty_mode);

  EXPECT_TRUE(vd_helper_mode_tracker_observe(&tracker, &baseline, true));
  ASSERT_TRUE(tracker.has_dirty_mode);
  EXPECT_EQ(tracker.dirty_mode.logical_width, 2420U);
  EXPECT_FALSE(tracker.dirty_mode.hidpi);
}

TEST(VirtualDisplayModePolicy, IgnoresRefreshOnlyChanges) {
  vd_helper_mode_tracker_t tracker {};
  const auto thirty_hertz = mode(1210, 834, 2420, 1668, 30.0, true);
  const auto sixty_hertz = mode(1210, 834, 2420, 1668, 60.0, true);

  EXPECT_FALSE(vd_helper_mode_tracker_observe(&tracker, &thirty_hertz, true));
  EXPECT_FALSE(vd_helper_mode_tracker_observe(&tracker, &sixty_hertz, true));
  EXPECT_FALSE(tracker.has_dirty_mode);
  EXPECT_DOUBLE_EQ(tracker.last_observed.refresh_rate, 60.0);
}

TEST(VirtualDisplayModePolicy, EffectiveModeMatchIncludesDimensionsScaleAndRefresh) {
  const auto effective = mode(1210, 834, 2420, 1668, 30.0, true);

  EXPECT_TRUE(vd_helper_effective_mode_matches(&effective, &effective));
  const auto nearby_refresh = mode(1210, 834, 2420, 1668, 30.9, true);
  EXPECT_TRUE(vd_helper_effective_mode_matches(&nearby_refresh, &effective));
  const auto wrong_refresh = mode(1210, 834, 2420, 1668, 60.0, true);
  EXPECT_FALSE(vd_helper_effective_mode_matches(&wrong_refresh, &effective));
  const auto wrong_scale = mode(1210, 834, 1210, 834, 30.0, false);
  EXPECT_FALSE(vd_helper_effective_mode_matches(&wrong_scale, &effective));
  const auto wrong_dimensions = mode(960, 540, 1920, 1080, 30.0, true);
  EXPECT_FALSE(vd_helper_effective_mode_matches(&wrong_dimensions, &effective));
}

TEST(VirtualDisplayModePolicy, InvalidSnapshotRetainsLastObservationAndDirtyMode) {
  vd_helper_mode_tracker_t tracker {};
  const auto baseline = mode(2420, 1668, 2420, 1668, 30.0, false);
  const auto scaled = mode(1210, 834, 2420, 1668, 30.0, true);
  const auto invalid = mode(0, 0, 0, 0, 0.0, false);

  ASSERT_FALSE(vd_helper_mode_tracker_observe(&tracker, &baseline, true));
  ASSERT_TRUE(vd_helper_mode_tracker_observe(&tracker, &scaled, true));
  ASSERT_TRUE(tracker.has_dirty_mode);

  EXPECT_FALSE(vd_helper_mode_tracker_observe(&tracker, &invalid, false));
  EXPECT_EQ(tracker.last_observed.logical_width, 1210U);
  EXPECT_EQ(tracker.dirty_mode.logical_width, 1210U);
  EXPECT_TRUE(tracker.has_dirty_mode);
}

TEST(VirtualDisplayModePolicy, FailedSaveCanRemainDirtyForRetry) {
  vd_helper_mode_tracker_t tracker {};
  const auto baseline = mode(2420, 1668, 2420, 1668, 30.0, false);
  const auto scaled = mode(1210, 834, 2420, 1668, 30.0, true);

  ASSERT_FALSE(vd_helper_mode_tracker_observe(&tracker, &baseline, true));
  ASSERT_TRUE(vd_helper_mode_tracker_observe(&tracker, &scaled, true));
  EXPECT_TRUE(tracker.has_dirty_mode);
  EXPECT_FALSE(vd_helper_mode_tracker_observe(&tracker, &scaled, true));
  EXPECT_TRUE(tracker.has_dirty_mode);
}
