/**
 * @file tests/unit/test_virtual_display_ownership.cpp
 * @brief Test pure virtual-display launch ownership transitions.
 */
#include "../tests_common.h"
#include "src/display_device.h"

TEST(VirtualDisplayOwnership, RejectsInvalidAndCompetingOwners) {
  display_device::virtual_display_ownership_t ownership;

  EXPECT_FALSE(ownership.reserve(0));
  EXPECT_TRUE(ownership.reserve(41));
  EXPECT_TRUE(ownership.reserve(41));
  EXPECT_FALSE(ownership.reserve(42));
}

TEST(VirtualDisplayOwnership, OnlyOwnerCanMarkCreatedAndRelease) {
  display_device::virtual_display_ownership_t ownership;

  ASSERT_TRUE(ownership.reserve(41));
  EXPECT_FALSE(ownership.mark_created(42));
  EXPECT_FALSE(ownership.is_created_by(41));
  EXPECT_TRUE(ownership.mark_created(41));
  EXPECT_TRUE(ownership.is_created_by(41));
  EXPECT_FALSE(ownership.is_created_by(42));
  EXPECT_FALSE(ownership.release(42));
  EXPECT_TRUE(ownership.is_created_by(41));
  EXPECT_TRUE(ownership.release(41));
  EXPECT_FALSE(ownership.is_created_by(41));
  EXPECT_TRUE(ownership.reserve(42));
}

TEST(VirtualDisplayOwnership, ForcedResetClearsReservationAndCreatedState) {
  display_device::virtual_display_ownership_t ownership;

  ASSERT_TRUE(ownership.reserve(41));
  ASSERT_TRUE(ownership.mark_created(41));
  ownership.reset();

  EXPECT_FALSE(ownership.is_created_by(41));
  EXPECT_TRUE(ownership.reserve(42));
}
