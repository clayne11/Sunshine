/**
 * @file src/platform/macos/input_target.h
 * @brief Declarations for resolving the current macOS pointer target.
 */
#pragma once

// standard includes
#include <cstdint>
#include <optional>

// local includes
#include "input_geometry.h"

namespace platf::macos_input {
  /**
   * @brief Record the display selected by the active capture backend.
   *
   * @param display_id CoreGraphics display identifier, or zero to clear it.
   */
  void set_capture_display(std::uint32_t display_id);

  /**
   * @brief Resolve and validate the current virtual, capture, or main display.
   *
   * @return Current pointer target viewport, or no value when none is usable.
   */
  std::optional<viewport_t> resolve_pointer_target();
}  // namespace platf::macos_input
