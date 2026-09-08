/**
 * @file src/platform/macos/capture_image.h
 * @brief CoreMedia/CoreVideo image helpers for macOS capture backends.
 */
#pragma once

// platform includes
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

// local includes
#include "src/platform/common.h"

namespace platf::macos_capture_image {
  /**
   * @brief Attach a captured sample buffer to a reusable macOS image.
   *
   * The image retains both the sample buffer and its pixel buffer. Existing
   * image storage remains retained until the replacement is fully prepared and
   * the previous pixel wrapper is released; callers must serialize access to
   * the image while replacing its data.
   *
   * @param sample_buffer Captured video sample buffer.
   * @param img Image wrapper to update. It must be a `platf::av_img_t`.
   * @return `true` when the sample contains a usable pixel buffer.
   */
  bool assign(CMSampleBufferRef sample_buffer, img_t &img);

  /**
   * @brief Create a black IOSurface-backed sample for encoder initialization.
   *
   * BGRA pixels are filled with zero. NV12 and P010 pixels use the selected
   * format's black luma value and neutral chroma value, including each
   * pixel-buffer plane's complete row stride.
   *
   * @param img Image wrapper to populate. It must be a `platf::av_img_t`.
   * @param width Frame width in pixels.
   * @param height Frame height in pixels.
   * @param pixel_format CoreVideo pixel format expected by the encoder device.
   * @return Zero on success, or nonzero when dimensions, allocation, locking,
   * or sample wrapping fails.
   */
  int make_dummy(img_t &img, int width, int height, OSType pixel_format);
}  // namespace platf::macos_capture_image
