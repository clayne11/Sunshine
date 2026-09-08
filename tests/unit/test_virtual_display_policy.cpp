/**
 * @file tests/unit/test_virtual_display_policy.cpp
 * @brief Test pure virtual-display snapshot and exclusivity policies.
 */

// test includes
#include <gtest/gtest.h>

// standard includes
#include <array>
#include <cstdint>

// local includes
#include "src/platform/macos/vd_helper_policy.h"

/**
 * @brief Test that only the two observed transient signatures are filtered.
 */
TEST(VirtualDisplayPolicy, RecognizesKnownTransientSignaturesOnly) {
  EXPECT_TRUE(vd_helper_is_known_transient_virtual_display(0x756e6b6e, 0x76697274));
  EXPECT_TRUE(vd_helper_is_known_transient_virtual_display(0xf0f0, 0x5678));
  EXPECT_FALSE(vd_helper_is_known_transient_virtual_display(0x1234, 0x5678));
  EXPECT_FALSE(vd_helper_is_known_transient_virtual_display(0xf0f0, 0x1234));
}

/**
 * @brief Test that exclusive mode requires an exact one-display active list.
 */
TEST(VirtualDisplayPolicy, RequiresExactVirtualOnlyActiveList) {
  constexpr std::uint32_t virtual_id = 160;
  const std::array<std::uint32_t, 1> only_virtual {virtual_id};
  const std::array<std::uint32_t, 2> virtual_and_orphan {virtual_id, 161};
  const std::array<std::uint32_t, 1> physical_only {1};

  EXPECT_TRUE(vd_helper_active_list_is_only_target(only_virtual.data(), static_cast<std::uint32_t>(only_virtual.size()), virtual_id));
  EXPECT_FALSE(vd_helper_active_list_is_only_target(virtual_and_orphan.data(), static_cast<std::uint32_t>(virtual_and_orphan.size()), virtual_id));
  EXPECT_FALSE(vd_helper_active_list_is_only_target(physical_only.data(), static_cast<std::uint32_t>(physical_only.size()), virtual_id));
  EXPECT_FALSE(vd_helper_active_list_is_only_target(nullptr, 0, virtual_id));
}
