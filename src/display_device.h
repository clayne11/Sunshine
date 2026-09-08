/**
 * @file src/display_device.h
 * @brief Declarations for display device handling.
 */
#pragma once

// standard includes
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

// lib includes
#include <display_device/display_power_interface.h>
#include <display_device/types.h>

// forward declarations
namespace platf {
  class deinit_t;
}

namespace config {
  struct video_t;
}

namespace rtsp_stream {
  struct launch_session_t;
}

namespace display_device {
  /**
   * @brief Track the launch session that owns the virtual-display lifecycle.
   * @note This class contains no platform calls and is not internally synchronized.
   */
  class virtual_display_ownership_t {
  public:
    /**
     * @brief Reserve the lifecycle for a launch session.
     * @param launch_session_id Launch-session identifier requesting ownership.
     * @return True when ownership was acquired or already belongs to the caller.
     */
    [[nodiscard]] bool reserve(uint32_t launch_session_id);

    /**
     * @brief Mark the owning session's native virtual display as created.
     * @param launch_session_id Launch-session identifier claiming creation.
     * @param client_certificate Certificate of the paired client that created the display.
     * @param width Requested logical width.
     * @param height Requested logical height.
     * @param fps Requested refresh rate.
     * @return True when the caller owns the lifecycle and the state was updated.
     */
    [[nodiscard]] bool mark_created(
      uint32_t launch_session_id,
      std::string_view client_certificate,
      int width,
      int height,
      int fps
    );

    /**
     * @brief Check whether the owning session has created its native display.
     * @param launch_session_id Launch-session identifier to inspect.
     * @return True when the caller owns a created virtual display.
     */
    [[nodiscard]] bool is_created_by(uint32_t launch_session_id) const;

    /**
     * @brief Check whether a session can safely reuse the created virtual display.
     * @param client_certificate Certificate of the requesting paired client.
     * @param width Requested logical width.
     * @param height Requested logical height.
     * @param fps Requested refresh rate.
     * @return True when the created display belongs to the exact client and requested tuple.
     */
    [[nodiscard]] bool matches(
      std::string_view client_certificate,
      int width,
      int height,
      int fps
    ) const;

    /**
     * @brief Release the lifecycle only when it belongs to the caller.
     * @param launch_session_id Launch-session identifier requesting release.
     * @return True when ownership was released.
     */
    [[nodiscard]] bool release(uint32_t launch_session_id);

    /**
     * @brief Clear ownership for forced shutdown or cancellation.
     */
    void reset();

  private:
    /** @brief Authenticated client and requested mode associated with a created display. */
    struct session_identity_t {
      std::string client_certificate;  ///< Certificate of the paired client that created the display.
      int width;  ///< Logical width requested when the display was created.
      int height;  ///< Logical height requested when the display was created.
      int fps;  ///< Refresh rate requested when the display was created.
    };

    std::optional<uint32_t> owner_id_;  ///< Launch session holding the lifecycle reservation.
    bool created_ {false};  ///< Whether the owner has created the native display.
    std::optional<session_identity_t> session_identity_;  ///< Exact session identity allowed to reuse the display.
  };

  /**
   * @brief Initialize the implementation and perform the initial state recovery (if needed).
   * @param persistence_filepath File location for reading/saving persistent state.
   * @param video_config User's video related configuration.
   * @returns A deinit_t instance that performs cleanup when destroyed.
   *
   * @examples
   * const config::video_t &video_config { config::video };
   * const auto init_guard { init("/my/persitence/file.state", video_config) };
   * @examples_end
   */
  [[nodiscard]] std::unique_ptr<platf::deinit_t> init(const std::filesystem::path &persistence_filepath, const config::video_t &video_config);

  /**
   * @brief Map the output name to a specific display.
   * @param output_name The user-configurable output name.
   * @returns Mapped display name or empty string if the output name could not be mapped.
   *
   * @examples
   * const auto mapped_name_config { map_output_name(config::video.output_name) };
   * const auto mapped_name_custom { map_output_name("{some-device-id}") };
   * @examples_end
   */
  [[nodiscard]] std::string map_output_name(const std::string &output_name);

  /**
   * @brief Ask the platform to wake displays before detection or capture.
   * @param display_name Platform capture selector.
   * @param timeout Maximum time to wait for platform-specific wake detection.
   * @returns True if the display was already available or the wake request succeeded.
   */
  [[nodiscard]] bool wake_display(const std::string &display_name, std::chrono::milliseconds timeout);

  /**
   * @brief Keep displays awake until the returned guard is destroyed.
   * @param reason Short human-readable reason for the power assertion.
   * @returns A guard owning the platform assertion, or nullptr if unsupported or unavailable.
   */
  [[nodiscard]] std::unique_ptr<DisplayPowerGuardInterface> keep_display_awake(const std::string &reason);

  /**
   * @brief Configure the display device based on the user configuration and the session information.
   * @note This is a convenience method for calling similar method of a different signature.
   *
   * @param video_config User's video related configuration.
   * @param session Session information.
   *
   * @examples
   * const std::shared_ptr<rtsp_stream::launch_session_t> launch_session;
   * const config::video_t &video_config { config::video };
   *
   * configure_display(video_config, *launch_session);
   * @examples_end
   */
  void configure_display(const config::video_t &video_config, const rtsp_stream::launch_session_t &session);

  /**
   * @brief Configure the display device using the provided configuration.
   *
   * In some cases configuring display can fail due to transient issues and
   * we will keep trying every 5 seconds, even if the stream has already started as there was
   * no possibility to apply settings before the stream start.
   *
   * Therefore, there is no return value as we still want to continue with the stream, so that
   * the users can do something about it once they are connected. Otherwise, we might
   * prevent users from logging in at all if we keep failing to apply configuration.
   *
   * @param config Configuration for the display.
   *
   * @examples
   * const SingleDisplayConfiguration valid_config { };
   * configure_display(valid_config);
   * @examples_end
   */
  void configure_display(const SingleDisplayConfiguration &config);

  /**
   * @brief Reserve virtual-display setup for one launch session.
   * @param video_config Display configuration, including the opt-in virtual-display policy.
   * @param launch_session_id Launch-session identifier requesting the reservation.
   * @return True when disabled or reserved; false when another launch owns the lifecycle.
   */
  [[nodiscard]] bool reserve_virtual_display(const config::video_t &video_config, uint32_t launch_session_id);

  /**
   * @brief Prepare a temporary macOS display after encoder probing succeeds.
   * @param video_config Display configuration, including the opt-in virtual-display policy.
   * @param session Client-requested dimensions and refresh rate.
   * @return True when disabled or ready; false when the requested virtual display cannot be created.
   */
  [[nodiscard]] bool create_virtual_display(const config::video_t &video_config, const rtsp_stream::launch_session_t &session);

  /**
   * @brief Check whether an existing virtual display matches a launch session.
   * @param session Authenticated client identity and requested mode to compare.
   * @return True when the live display was created for the same certificate and tuple.
   */
  [[nodiscard]] bool virtual_display_matches(const rtsp_stream::launch_session_t &session);

  /**
   * @brief Release a virtual display only when it belongs to a launch session.
   * @param launch_session_id Launch-session identifier requesting cleanup.
   * @return True when the caller owned and released the lifecycle.
   */
  [[nodiscard]] bool destroy_virtual_display(uint32_t launch_session_id);

  /**
   * @brief Release a temporary virtual display and its session-only layout.
   * @note Safe to call when no virtual display exists and on non-macOS platforms.
   */
  void destroy_virtual_display();

  /**
   * @brief Revert the display configuration and restore the previous state.
   *
   * In case the state could not be restored, by default it will be retried again in 5 seconds
   * (repeating indefinitely until success or until persistence is reset).
   *
   * @examples
   * revert_configuration();
   * @examples_end
   */
  void revert_configuration();

  /**
   * @brief Reset persisted display state and the captured initial state.
   *
   * This is normally used to get out of the "broken" state where the algorithm wants
   * to restore the initial display state, but it is no longer possible.
   *
   * This could happen if the display is no longer available or the hardware was changed
   * and the device ids no longer match.
   *
   * The user then accepts that Sunshine is not able to restore the state and "agrees" to
   * do it manually.
   *
   * @return True if persistence was reset, false otherwise.
   * @note Whether the function succeeds or fails, any of the scheduled "retries" from
   *       other methods will be stopped to not interfere with the user actions.
   *
   * @examples
   * const auto result = reset_persistence();
   * @examples_end
   */
  [[nodiscard]] bool reset_persistence();

  /**
   * @brief Enumerate the available devices.
   * @return A list of devices.
   *
   * @examples
   * const auto devices = enumerate_devices();
   * @examples_end
   */
  [[nodiscard]] EnumeratedDeviceList enumerate_devices();

  /**
   * @brief A tag structure indicating that configuration parsing has failed.
   */
  struct failed_to_parse_tag_t {};

  /**
   * @brief A tag structure indicating that configuration is disabled.
   */
  struct configuration_disabled_tag_t {};

  /**
   * @brief Parse the user configuration and the session information.
   * @param video_config User's video related configuration.
   * @param session Session information.
   * @return Parsed single display configuration or
   *         a tag indicating that the parsing has failed or
   *         a tag indicating that the user does not want to perform any configuration.
   *
   * @examples
   * const std::shared_ptr<rtsp_stream::launch_session_t> launch_session;
   * const config::video_t &video_config { config::video };
   *
   * const auto config { parse_configuration(video_config, *launch_session) };
   * if (const auto *parsed_config { std::get_if<SingleDisplayConfiguration>(&result) }; parsed_config) {
   *    configure_display(*config);
   * }
   * @examples_end
   */
  [[nodiscard]] std::variant<failed_to_parse_tag_t, configuration_disabled_tag_t, SingleDisplayConfiguration> parse_configuration(const config::video_t &video_config, const rtsp_stream::launch_session_t &session);
}  // namespace display_device
