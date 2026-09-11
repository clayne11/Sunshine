/**
 * @file tests/unit/platform/macos/test_display_identity.cpp
 * @brief Unit tests for macOS virtual-display identity material.
 */
#include "src/platform/macos/display_identity.h"

#include <gtest/gtest.h>

TEST(MacOSDisplayIdentity, KeysByClientAndRequestedDimensions) {
  const macos_display_requested_mode_t requested {2420, 1668, 30};

  EXPECT_EQ(
    display_device::macos::virtual_display_identity_key("client-a", requested),
    "client-a:2420x1668"
  );
  EXPECT_NE(
    display_device::macos::virtual_display_identity_key("client-a", requested),
    display_device::macos::virtual_display_identity_key("client-b", requested)
  );
  EXPECT_NE(
    display_device::macos::virtual_display_identity_key("client-a", requested),
    display_device::macos::virtual_display_identity_key("client-a", macos_display_requested_mode_t {1920, 1668, 30})
  );
  EXPECT_NE(
    display_device::macos::virtual_display_identity_key("client-a", requested),
    display_device::macos::virtual_display_identity_key("client-a", macos_display_requested_mode_t {2420, 1080, 30})
  );
}

TEST(MacOSDisplayIdentity, RefreshRateDoesNotChangeIdentity) {
  const macos_display_requested_mode_t thirty_hertz {2420, 1668, 30};
  const macos_display_requested_mode_t sixty_hertz {2420, 1668, 60};

  EXPECT_EQ(
    display_device::macos::virtual_display_identity_key("client-a", thirty_hertz),
    display_device::macos::virtual_display_identity_key("client-a", sixty_hertz)
  );
}
