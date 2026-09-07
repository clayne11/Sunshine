/**
 * @file src/platform/macos/input.cpp
 * @brief Definitions for libvirtualhid-backed macOS input handling.
 */

// platform includes
#include <ApplicationServices/ApplicationServices.h>

// standard includes
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

// local includes
#include "input_target.h"
#include "src/config.h"
#include "src/platform/virtualhid_input.h"
#include "virtual_display.h"

namespace platf {
  namespace macos_input {
    namespace {
      std::atomic<std::uint32_t> capture_display_id {};  ///< Display selected by the active capture backend.

      /**
       * @brief Resolve one CoreGraphics display identifier to validated bounds.
       *
       * @param display_id CoreGraphics display identifier.
       * @return Validated pointer viewport, or no value when the display is unavailable.
       */
      std::optional<viewport_t> target_for_display(std::uint32_t display_id) {
        if (display_id == 0 || !CGDisplayIsOnline(display_id) || !CGDisplayIsActive(display_id)) {
          return std::nullopt;
        }

        const auto bounds = CGDisplayBounds(display_id);
        return viewport_from_rect({bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height});
      }
    }  // namespace

    void set_capture_display(std::uint32_t display_id) {
      capture_display_id.store(display_id, std::memory_order_release);
    }

    std::optional<viewport_t> resolve_pointer_target() {
      if (config::video.virtual_display) {
        return target_for_display(virtual_display_get_id());
      }

      const std::array candidates {
        virtual_display_get_id(),
        capture_display_id.load(std::memory_order_acquire),
        static_cast<std::uint32_t>(CGMainDisplayID())
      };

      for (const auto display_id : candidates) {
        if (const auto target = target_for_display(display_id)) {
          return target;
        }
      }

      return std::nullopt;
    }
  }  // namespace macos_input

  std::optional<util::point_t> get_mouse_loc(input_t & /*input*/) {
    const auto event = CGEventCreate(nullptr);
    if (!event) {
      return std::nullopt;
    }

    const auto current = CGEventGetLocation(event);
    CFRelease(event);
    return util::point_t {current.x, current.y};
  }

  platform_caps::caps_t get_capabilities() {
    platform_caps::caps_t caps = 0;
    const auto runtime = virtualhid::create_runtime();
    if (!runtime) {
      return caps;
    }

    const auto &capabilities = runtime->capabilities();
    if (capabilities.supports_gamepad && virtualhid::configured_gamepad_supports_controller_extensions()) {
      caps |= platform_caps::controller_touch;
    }
    if (config::input.native_pen_touch && (capabilities.supports_touchscreen || capabilities.supports_pen_tablet)) {
      caps |= platform_caps::pen_touch;
    }

    return caps;
  }

  std::vector<supported_gamepad_t> &supported_gamepads(input_t *input) {
    static std::vector<supported_gamepad_t> gamepads;
    if (!input || !input->get()) {
      gamepads = virtualhid::static_supported_gamepads();
      return gamepads;
    }

    gamepads = virtualhid::supported_gamepads(virtualhid::get_input_context(*input).runtime.get());
    return gamepads;
  }

}  // namespace platf
