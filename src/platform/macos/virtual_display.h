/**
 * @file src/platform/macos/virtual_display.h
 * @brief Declarations for CGVirtualDisplay-based virtual display management on macOS.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include "display_preferences.h"

#include <stdbool.h>
#include <stdint.h>

  /**
   * @brief Snapshot of the virtual-display controller state.
   */
  typedef struct virtual_display_state_t {
    uint32_t display_id;  ///< Active virtual display ID, or zero when unavailable.
    bool requested;  ///< Whether a successful request remains active.
  } virtual_display_state_t;

  /**
   * @brief Complete virtual-display request passed to the helper process.
   *
   * The requested tuple is the current Moonlight request. The effective mode
   * is either that tuple or a validated per-client override loaded from the
   * profile. Logical and backing dimensions remain separate so a HiDPI mode
   * does not get mistaken for a different requested stream size.
   */
  typedef struct virtual_display_request_t {
    macos_display_requested_mode_t requested;  ///< Current Moonlight request.
    macos_display_mode_t effective;  ///< Mode to offer and select for this connection.
    uint32_t helper_serial;  ///< Stable display serial derived from the paired client certificate.
    const char *profile_directory;  ///< Directory used by the holder to save a changed mode.
    const char *certificate_fingerprint;  ///< Paired client certificate fingerprint, or null when unavailable.
    bool has_preference;  ///< Whether effective came from a validated saved override.
    bool exclusive;  ///< Whether the virtual display temporarily owns the active desktop.
  } virtual_display_request_t;

  /**
   * @brief Create a virtual display with the specified resolution and refresh rate.
   * @param width Display width in pixels.
   * @param height Display height in pixels.
   * @param fps Refresh rate in Hz.
   * @param exclusive Whether the virtual display should temporarily be the only active display.
   * @return The CGDirectDisplayID of the created display, or 0 on failure.
   */
  uint32_t virtual_display_create(int width, int height, int fps, bool exclusive);

  /**
   * @brief Create a virtual display using a per-client mode request.
   * @param request Requested and effective mode metadata, persistence context, and display policy.
   * @return The CGDirectDisplayID of the created display, or 0 on failure.
   */
  uint32_t virtual_display_create_with_request(const virtual_display_request_t *request);

  /**
   * @brief Destroy the currently active virtual display.
   */
  void virtual_display_destroy(void);

  /**
   * @brief Get the display ID of the currently active virtual display.
   * @return The CGDirectDisplayID, or 0 if no virtual display is active.
   */
  uint32_t virtual_display_get_id(void);

  /**
   * @brief Report whether a virtual display was requested for the current lifecycle.
   * @return True until the caller explicitly destroys or clears the request.
   */
  bool virtual_display_is_requested(void);

  /**
   * @brief Read the display ID and request flag under one controller lock.
   * @param state Receives the atomic controller snapshot; ignored when null.
   */
  void virtual_display_get_state(virtual_display_state_t *state);

#ifdef __cplusplus
}
#endif
