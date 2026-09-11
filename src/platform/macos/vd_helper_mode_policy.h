/**
 * @file src/platform/macos/vd_helper_mode_policy.h
 * @brief Pure tracking policy for changed macOS virtual-display modes.
 */
#pragma once

#include "display_preferences.h"

#include <math.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

  /**
   * @brief State retained while observing one live virtual display.
   */
  typedef struct vd_helper_mode_tracker_t {
    macos_display_mode_t last_observed;  ///< Most recent complete observed mode.
    macos_display_mode_t dirty_mode;  ///< Most recent changed mode awaiting a successful save.
    bool has_last_observed;  ///< Whether last_observed contains a complete snapshot.
    bool has_dirty_mode;  ///< Whether dirty_mode still needs to be saved.
  } vd_helper_mode_tracker_t;

  /**
   * @brief Compare the resolution mapping represented by two full mode snapshots.
   * @param lhs First complete mode.
   * @param rhs Second complete mode.
   * @return True when logical dimensions, backing dimensions, and HiDPI state match.
   */
  static inline bool vd_helper_same_resolution_mapping(const macos_display_mode_t *lhs, const macos_display_mode_t *rhs) {
    return lhs && rhs && lhs->logical_width == rhs->logical_width && lhs->logical_height == rhs->logical_height &&
           lhs->pixel_width == rhs->pixel_width && lhs->pixel_height == rhs->pixel_height && lhs->hidpi == rhs->hidpi;
  }

  /**
   * @brief Check whether an observed mode satisfies the requested effective mode.
   * @param observed Complete mode reported by CoreGraphics.
   * @param effective Requested logical, backing, scaling, and refresh mode.
   * @return True when dimensions and scale match and refresh differs by at most one hertz.
   */
  static inline bool vd_helper_effective_mode_matches(const macos_display_mode_t *observed, const macos_display_mode_t *effective) {
    return vd_helper_same_resolution_mapping(observed, effective) &&
           fabs(observed->refresh_rate - effective->refresh_rate) <= 1.0;
  }

  /**
   * @brief Record a validated observation and retain changed mappings for saving.
   *
   * The first valid observation establishes the baseline without becoming dirty.
   * Invalid observations leave all prior state intact. Refresh-only changes update
   * the last observation but do not create a persistence write.
   *
   * @param tracker Mutable observation state.
   * @param mode Candidate full mode snapshot.
   * @param snapshot_valid Whether the candidate passed the strict full-mode validator.
   * @return True when dimensions or HiDPI state changed from the last observation.
   */
  static inline bool vd_helper_mode_tracker_observe(
    vd_helper_mode_tracker_t *tracker,
    const macos_display_mode_t *mode,
    bool snapshot_valid
  ) {
    if (!tracker || !mode || !snapshot_valid) {
      return false;
    }

    if (!tracker->has_last_observed) {
      tracker->last_observed = *mode;
      tracker->has_last_observed = true;
      return false;
    }

    const bool changed = !vd_helper_same_resolution_mapping(&tracker->last_observed, mode);
    tracker->last_observed = *mode;
    if (changed) {
      tracker->dirty_mode = *mode;
      tracker->has_dirty_mode = true;
    }
    return changed;
  }

  /**
   * @brief Mark the retained dirty mode as saved.
   * @param tracker Mutable observation state.
   */
  static inline void vd_helper_mode_tracker_mark_saved(vd_helper_mode_tracker_t *tracker) {
    if (tracker) {
      tracker->has_dirty_mode = false;
    }
  }

#ifdef __cplusplus
}
#endif
