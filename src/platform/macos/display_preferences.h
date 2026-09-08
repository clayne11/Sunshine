/**
 * @file src/platform/macos/display_preferences.h
 * @brief Per-client virtual-display mode persistence for macOS.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

  /** @brief Maximum logical display dimension accepted by the preference store. */
  enum {
    MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION = 16384,  ///< Largest accepted logical width or height.
    MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION = 32768,  ///< Largest accepted backing-pixel width or height.
    MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE = 240  ///< Largest accepted refresh rate in hertz.
  };

  /**
   * @brief A display tuple requested by a Moonlight client.
   */
  typedef struct macos_display_requested_mode_t {
    uint32_t width;  ///< Requested logical width in pixels.
    uint32_t height;  ///< Requested logical height in pixels.
    uint32_t refresh_rate;  ///< Requested refresh rate in hertz.
  } macos_display_requested_mode_t;

  /**
   * @brief A display mode observed from CoreGraphics.
   *
   * Logical dimensions describe the coordinate space used by applications.
   * Pixel dimensions describe the backing framebuffer. They may differ when
   * macOS exposes a HiDPI mode.
   */
  typedef struct macos_display_mode_t {
    uint32_t logical_width;  ///< Logical mode width in pixels.
    uint32_t logical_height;  ///< Logical mode height in pixels.
    uint32_t pixel_width;  ///< Backing pixel width.
    uint32_t pixel_height;  ///< Backing pixel height.
    double refresh_rate;  ///< Observed refresh rate in hertz.
    bool hidpi;  ///< Whether logical and backing dimensions use HiDPI scaling.
  } macos_display_mode_t;

  /**
   * @brief A persisted per-client mode preference.
   */
  typedef struct macos_display_preference_t {
    macos_display_requested_mode_t requested;  ///< Moonlight tuple that selected this preference.
    macos_display_mode_t mode;  ///< Explicit mode observed for that tuple.
  } macos_display_preference_t;

  /**
   * @brief Load a validated preference for a paired client.
   *
   * A preference is returned only when the file, certificate fingerprint, and
   * requested tuple all match the supplied values. Missing, malformed, or stale
   * entries are treated as absent.
   *
   * @param profile_directory Directory in which per-client preference files live.
   * @param certificate_fingerprint SHA-256 certificate fingerprint in lowercase or uppercase hexadecimal.
   * @param requested Current Moonlight requested tuple.
   * @param preference Receives the validated preference when one exists.
   * @return True when a matching preference was loaded.
   */
  bool macos_display_preferences_load(
    const char *profile_directory,
    const char *certificate_fingerprint,
    const macos_display_requested_mode_t *requested,
    macos_display_preference_t *preference
  );

  /**
   * @brief Atomically save a per-client mode preference.
   *
   * The file is written beside the final path and then replaced with an atomic
   * same-directory rename. Invalid dimensions, rates, or fingerprints are
   * rejected before any file is changed.
   *
   * @param profile_directory Directory in which the per-client file is written.
   * @param certificate_fingerprint SHA-256 certificate fingerprint in lowercase or uppercase hexadecimal.
   * @param preference Preference to validate and save.
   * @return True when the preference was written and atomically installed.
   */
  bool macos_display_preferences_save(
    const char *profile_directory,
    const char *certificate_fingerprint,
    const macos_display_preference_t *preference
  );

#ifdef __cplusplus
}
#endif
