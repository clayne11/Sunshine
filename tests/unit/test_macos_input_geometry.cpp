/**
 * @file tests/unit/test_macos_input_geometry.cpp
 * @brief Tests for macOS pointer source and target geometry.
 */

// standard includes
#include <limits>

// lib includes
#include <gtest/gtest.h>

// local includes
#include "src/platform/macos/input_geometry.h"

namespace {
  using platf::macos_input::local_absolute_point;
  using platf::macos_input::viewport_from_rect;

  TEST(MacosInputGeometryTest, KeepsIPadCoordinatesIndependentOfStartupScale) {
    const auto point = local_absolute_point({2420.0, 1668.0}, {0.0, 0.0, 2420.0, 1668.0});

    ASSERT_TRUE(point);
    EXPECT_DOUBLE_EQ(point->x, 2420.0);
    EXPECT_DOUBLE_EQ(point->y, 1668.0);
  }

  TEST(MacosInputGeometryTest, RemovesNegativeTouchPortOffset) {
    const auto point = local_absolute_point({-960.0, 540.0}, {-1920.0, 0.0, 1920.0, 1080.0});

    ASSERT_TRUE(point);
    EXPECT_DOUBLE_EQ(point->x, 960.0);
    EXPECT_DOUBLE_EQ(point->y, 540.0);
  }

  TEST(MacosInputGeometryTest, ClampsOutOfRangeSourceCoordinates) {
    const auto before = local_absolute_point({-2500.0, -100.0}, {-1920.0, 0.0, 1920.0, 1080.0});
    const auto after = local_absolute_point({500.0, 1500.0}, {-1920.0, 0.0, 1920.0, 1080.0});

    ASSERT_TRUE(before);
    ASSERT_TRUE(after);
    EXPECT_DOUBLE_EQ(before->x, 0.0);
    EXPECT_DOUBLE_EQ(before->y, 0.0);
    EXPECT_DOUBLE_EQ(after->x, 1920.0);
    EXPECT_DOUBLE_EQ(after->y, 1080.0);
  }

  TEST(MacosInputGeometryTest, ConvertsChangingTargetBounds) {
    const auto old_target = viewport_from_rect({0.0, 0.0, 1920.0, 1080.0});
    const auto new_target = viewport_from_rect({-2560.0, 180.0, 2560.0, 1440.0});

    ASSERT_TRUE(old_target);
    ASSERT_TRUE(new_target);
    EXPECT_EQ(old_target->offset_x, 0);
    EXPECT_EQ(old_target->width, 1920);
    EXPECT_EQ(new_target->offset_x, -2560);
    EXPECT_EQ(new_target->offset_y, 180);
    EXPECT_EQ(new_target->width, 2560);
    EXPECT_EQ(new_target->height, 1440);
  }

  TEST(MacosInputGeometryTest, RejectsZeroNonFiniteAndOutOfRangeGeometry) {
    const auto nan = std::numeric_limits<double>::quiet_NaN();
    const auto inf = std::numeric_limits<double>::infinity();

    EXPECT_FALSE(local_absolute_point({10.0, 10.0}, {0.0, 0.0, 0.0, 1080.0}));
    EXPECT_FALSE(local_absolute_point({nan, 10.0}, {0.0, 0.0, 1920.0, 1080.0}));
    EXPECT_FALSE(viewport_from_rect({0.0, 0.0, 0.0, 1080.0}));
    EXPECT_FALSE(viewport_from_rect({inf, 0.0, 1920.0, 1080.0}));
    EXPECT_FALSE(viewport_from_rect({0.0, 0.0, inf, 1080.0}));
    EXPECT_FALSE(viewport_from_rect({0.0, 0.0, 4294967296.0, 1080.0}));
  }
}  // namespace
