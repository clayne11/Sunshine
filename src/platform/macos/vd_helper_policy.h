/**
 * @file src/platform/macos/vd_helper_policy.h
 * @brief Pure virtual-display snapshot policy predicates.
 */
#pragma once

// standard includes
#include <stdbool.h>
#include <stdint.h>

/**
 * @brief Check whether a display signature identifies a known transient virtual display.
 *
 * The first signature is the macOS fallback observed after a failed physical
 * restore. The second is Sunshine's own descriptor, which can remain orphaned
 * in WindowServer while a helper is being replaced. No other signatures are
 * treated as transient.
 *
 * @param vendor CoreGraphics vendor number.
 * @param model CoreGraphics model number.
 * @return True for one of the two known transient virtual-display signatures.
 */
static inline bool vd_helper_is_known_transient_virtual_display(uint32_t vendor, uint32_t model) {
  static const uint32_t fallbackVendor = UINT32_C(0x756e6b6e);  ///< `unkn` fallback vendor.
  static const uint32_t fallbackModel = UINT32_C(0x76697274);  ///< `virt` fallback model.
  static const uint32_t sunshineVendor = UINT32_C(0x0000f0f0);  ///< Sunshine virtual-display vendor.
  static const uint32_t sunshineModel = UINT32_C(0x00005678);  ///< Sunshine virtual-display model.
  return (vendor == fallbackVendor && model == fallbackModel) || (vendor == sunshineVendor && model == sunshineModel);
}

/**
 * @brief Check that an active display list contains exactly one target.
 *
 * This predicate intentionally does not ignore transient virtual displays;
 * exclusive mode must still prove that the requested display is the sole
 * active display.
 *
 * @param active_display_ids Active display IDs, or null when count is zero.
 * @param display_count Number of entries in active_display_ids.
 * @param target_id Requested virtual display ID.
 * @return True only when the list contains target_id and nothing else.
 */
static inline bool vd_helper_active_list_is_only_target(const uint32_t *active_display_ids, uint32_t display_count, uint32_t target_id) {
  return active_display_ids != 0 && display_count == 1 && active_display_ids[0] == target_id;
}
