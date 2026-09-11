/**
 * @file src/platform/macos/display_identity.h
 * @brief Stable identity material for per-client virtual displays on macOS.
 */
#pragma once

#include "display_preferences.h"

#include <string>
#include <string_view>

namespace display_device::macos {
  /**
   * @brief Build the stable identity key for one client-resolution mapping.
   *
   * Refresh rate is deliberately excluded. Reconnecting at a different rate
   * keeps the same resolution mapping while the display lifecycle still
   * recreates its modes for the current rate.
   *
   * @param certificate_fingerprint Canonical paired-client certificate fingerprint.
   * @param requested Current client-requested mode.
   * @return Identity material containing the client and requested dimensions.
   */
  inline std::string virtual_display_identity_key(
    std::string_view certificate_fingerprint,
    const macos_display_requested_mode_t &requested
  ) {
    return std::string {certificate_fingerprint} + ":" + std::to_string(requested.width) + "x" + std::to_string(requested.height);
  }
}  // namespace display_device::macos
