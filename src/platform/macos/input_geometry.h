/**
 * @file src/platform/macos/input_geometry.h
 * @brief Pure geometry helpers for macOS pointer targeting.
 */
#pragma once

// standard includes
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>

namespace platf::macos_input {
  /**
   * @brief Floating-point point used by coordinate transforms.
   */
  struct point_t {
    double x {};  ///< Horizontal coordinate.
    double y {};  ///< Vertical coordinate.
  };

  /**
   * @brief Floating-point rectangle used by coordinate transforms.
   */
  struct rect_t {
    double x {};  ///< Horizontal origin.
    double y {};  ///< Vertical origin.
    double width {};  ///< Rectangle width.
    double height {};  ///< Rectangle height.
  };

  /**
   * @brief Integral viewport accepted by libvirtualhid.
   */
  struct viewport_t {
    std::int32_t offset_x {};  ///< Horizontal origin.
    std::int32_t offset_y {};  ///< Vertical origin.
    std::int32_t width {};  ///< Viewport width.
    std::int32_t height {};  ///< Viewport height.
  };

  /**
   * @brief Validate and convert CoreGraphics-style bounds to an input viewport.
   *
   * @param rect Rectangle to convert.
   * @return Integral viewport, or no value for non-finite, empty, or out-of-range bounds.
   */
  inline std::optional<viewport_t> viewport_from_rect(const rect_t &rect) {
    constexpr auto int_min = static_cast<double>(std::numeric_limits<std::int32_t>::min());
    constexpr auto int_max = static_cast<double>(std::numeric_limits<std::int32_t>::max());
    if (!std::isfinite(rect.x) || !std::isfinite(rect.y) || !std::isfinite(rect.width) || !std::isfinite(rect.height) || rect.x < int_min || rect.x > int_max || rect.y < int_min || rect.y > int_max || rect.width < 1.0 || rect.width > int_max || rect.height < 1.0 || rect.height > int_max) {
      return std::nullopt;
    }

    return viewport_t {
      static_cast<std::int32_t>(std::lround(rect.x)),
      static_cast<std::int32_t>(std::lround(rect.y)),
      static_cast<std::int32_t>(std::lround(rect.width)),
      static_cast<std::int32_t>(std::lround(rect.height))
    };
  }

  /**
   * @brief Convert an already-transformed touch-port coordinate to local source coordinates.
   *
   * @param point Absolute point produced by Sunshine's client-to-touch-port transform.
   * @param touch_port Touch-port bounds that define the source coordinate space.
   * @return Local source point, or no value for invalid geometry.
   */
  inline std::optional<point_t> local_absolute_point(point_t point, const rect_t &touch_port) {
    if (!std::isfinite(point.x) || !std::isfinite(point.y) || !std::isfinite(touch_port.x) || !std::isfinite(touch_port.y) || !std::isfinite(touch_port.width) || !std::isfinite(touch_port.height) || touch_port.width <= 0.0 || touch_port.height <= 0.0) {
      return std::nullopt;
    }

    return point_t {
      std::clamp(point.x - touch_port.x, 0.0, touch_port.width),
      std::clamp(point.y - touch_port.y, 0.0, touch_port.height)
    };
  }
}  // namespace platf::macos_input
