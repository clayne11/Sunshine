/**
 * @file src/platform/macos/capture_image.mm
 * @brief CoreMedia/CoreVideo image helpers for macOS capture backends.
 */

// standard includes
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>

// platform includes
#import <Foundation/Foundation.h>

// local includes
#include "capture_image.h"
#include "src/logging.h"
#include "src/platform/macos/av_img_t.h"

namespace platf::macos_capture_image {
  namespace {
    /**
     * @brief Pixel format families supported by the dummy image path.
     */
    enum class pixel_format_e {
      bgra,  ///< Packed 8-bit BGRA pixels.
      nv12,  ///< 8-bit bi-planar 4:2:0 pixels.
      p010,  ///< 10-bit bi-planar 4:2:0 pixels.
    };

    /**
     * @brief Format family and range needed for black-frame initialization.
     */
    struct pixel_format_info_t {
      pixel_format_e format;  ///< Pixel format family.
      bool full_range;  ///< Whether luma uses the full-range black value.
    };

    /**
     * @brief Classify the pixel formats supported by the dummy image path.
     *
     * @param pixel_format CoreVideo pixel format.
     * @return Format information, or nullopt for an unsupported format.
     */
    std::optional<pixel_format_info_t> pixel_format_info(OSType pixel_format) {
      if (pixel_format == kCVPixelFormatType_32BGRA) {
        return pixel_format_info_t {pixel_format_e::bgra, false};
      }
      if (pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        return pixel_format_info_t {pixel_format_e::nv12, false};
      }
      if (pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        return pixel_format_info_t {pixel_format_e::nv12, true};
      }
      if (pixel_format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
        return pixel_format_info_t {pixel_format_e::p010, false};
      }
      if (pixel_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
        return pixel_format_info_t {pixel_format_e::p010, true};
      }
      return std::nullopt;
    }

    /**
     * @brief Return the first usable data plane of a pixel buffer.
     *
     * @param pixel_buffer Pixel buffer whose base address is already locked.
     * @return Plane zero data address, or null when no usable address exists.
     */
    uint8_t *pixel_data(CVPixelBufferRef pixel_buffer) {
      if (!pixel_buffer) {
        return nullptr;
      }

      if (!CVPixelBufferIsPlanar(pixel_buffer)) {
        return static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixel_buffer));
      }

      if (CVPixelBufferGetPlaneCount(pixel_buffer) == 0) {
        return nullptr;
      }
      return static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0));
    }

    /**
     * @brief Check that every plane needed by an image wrapper is accessible.
     *
     * @param pixel_buffer Pixel buffer whose base address is already locked.
     * @return `true` when the pixel buffer has positive dimensions and data.
     */
    bool usable_pixel_buffer(CVPixelBufferRef pixel_buffer) {
      if (!pixel_buffer || CVPixelBufferGetWidth(pixel_buffer) == 0 || CVPixelBufferGetHeight(pixel_buffer) == 0) {
        return false;
      }

      if (!CVPixelBufferIsPlanar(pixel_buffer)) {
        return pixel_data(pixel_buffer) != nullptr && CVPixelBufferGetBytesPerRow(pixel_buffer) != 0;
      }

      const auto plane_count = CVPixelBufferGetPlaneCount(pixel_buffer);
      if (plane_count == 0) {
        return false;
      }
      for (size_t plane = 0; plane < plane_count; ++plane) {
        if (!CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane) || CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane) == 0 || CVPixelBufferGetWidthOfPlane(pixel_buffer, plane) == 0 || CVPixelBufferGetHeightOfPlane(pixel_buffer, plane) == 0) {
          return false;
        }
      }
      return true;
    }

    /**
     * @brief Fill every byte in each row of a pixel-buffer plane.
     *
     * @param pixel_buffer Pixel buffer whose base address is locked.
     * @param plane Plane index.
     * @param value Byte value to write.
     * @return `true` when the plane has a valid row address and stride.
     */
    bool fill_plane_bytes(CVPixelBufferRef pixel_buffer, size_t plane, uint8_t value) {
      auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
      const auto row_bytes = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);
      const auto row_count = CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
      if (!base || row_bytes == 0 || row_count == 0) {
        return false;
      }

      for (size_t row = 0; row < row_count; ++row) {
        std::memset(base + row * row_bytes, value, row_bytes);
      }
      return true;
    }

    /**
     * @brief Fill every 16-bit word in each row of a P010 plane.
     *
     * @param pixel_buffer Pixel buffer whose base address is locked.
     * @param plane Plane index.
     * @param value Native-endian 16-bit value to write.
     * @return `true` when the plane has a valid even row stride.
     */
    bool fill_plane_words(CVPixelBufferRef pixel_buffer, size_t plane, uint16_t value) {
      auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
      const auto row_bytes = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);
      const auto row_count = CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
      if (!base || row_bytes == 0 || row_count == 0 || row_bytes % sizeof(value) != 0) {
        return false;
      }

      for (size_t row = 0; row < row_count; ++row) {
        auto *row_base = base + row * row_bytes;
        for (size_t offset = 0; offset < row_bytes; offset += sizeof(value)) {
          std::memcpy(row_base + offset, &value, sizeof(value));
        }
      }
      return true;
    }

    /**
     * @brief Fill an allocated pixel buffer with format-correct black.
     *
     * @param pixel_buffer Pixel buffer whose base address is locked.
     * @param format Pixel format information.
     * @return `true` when every expected plane was initialized.
     */
    bool fill_black(CVPixelBufferRef pixel_buffer, const pixel_format_info_t &format) {
      if (format.format == pixel_format_e::bgra) {
        auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixel_buffer));
        const auto row_bytes = CVPixelBufferGetBytesPerRow(pixel_buffer);
        const auto row_count = CVPixelBufferGetHeight(pixel_buffer);
        if (!base || row_bytes == 0 || row_count == 0) {
          return false;
        }
        for (size_t row = 0; row < row_count; ++row) {
          std::memset(base + row * row_bytes, 0, row_bytes);
        }
        return true;
      }

      if (!CVPixelBufferIsPlanar(pixel_buffer) || CVPixelBufferGetPlaneCount(pixel_buffer) < 2) {
        return false;
      }

      if (format.format == pixel_format_e::nv12) {
        const auto luma = format.full_range ? 0x00 : 0x10;
        return fill_plane_bytes(pixel_buffer, 0, luma) && fill_plane_bytes(pixel_buffer, 1, 0x80);
      }

      const auto luma = static_cast<uint16_t>((format.full_range ? 0 : 64) << 6);
      const auto chroma = static_cast<uint16_t>(512 << 6);
      return fill_plane_words(pixel_buffer, 0, luma) && fill_plane_words(pixel_buffer, 1, chroma);
    }

    /**
     * @brief Release a CoreVideo pixel buffer and log a failure.
     *
     * @param pixel_buffer Pixel buffer to release.
     * @param message Failure message.
     * @return Nonzero helper failure status.
     */
    int fail_dummy(CVPixelBufferRef pixel_buffer, const char *message) {
      if (pixel_buffer) {
        CVPixelBufferRelease(pixel_buffer);
      }
      BOOST_LOG(error) << message;
      return 1;
    }
  }  // namespace

  bool assign(CMSampleBufferRef sample_buffer, img_t &img) {
    auto *av_img = dynamic_cast<av_img_t *>(&img);
    if (!sample_buffer || !av_img) {
      return false;
    }

    auto *sample_pixel_buffer = CMSampleBufferGetImageBuffer(sample_buffer);
    if (!sample_pixel_buffer) {
      return false;
    }

    auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sample_buffer);
    auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);
    if (!usable_pixel_buffer(new_pixel_buffer->buf)) {
      return false;
    }

    auto *new_data = pixel_data(new_pixel_buffer->buf);
    const auto width = static_cast<int>(CVPixelBufferGetWidth(new_pixel_buffer->buf));
    const auto height = static_cast<int>(CVPixelBufferGetHeight(new_pixel_buffer->buf));
    const auto row_pitch = static_cast<int>(CVPixelBufferIsPlanar(new_pixel_buffer->buf) ? CVPixelBufferGetBytesPerRowOfPlane(new_pixel_buffer->buf, 0) : CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf));
    if (!new_data || width <= 0 || height <= 0 || row_pitch <= 0) {
      return false;
    }

    auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
      av_img->sample_buffer,
      av_img->pixel_buffer,
      img.data
    );

    av_img->sample_buffer = std::move(new_sample_buffer);
    av_img->pixel_buffer = std::move(new_pixel_buffer);
    img.data = new_data;
    img.width = width;
    img.height = height;
    img.row_pitch = row_pitch;
    img.pixel_pitch = row_pitch / width;

    old_data_retainer.reset();
    return true;
  }

  int make_dummy(img_t &img, int width, int height, OSType pixel_format) {
    if (width <= 0 || height <= 0 || !dynamic_cast<av_img_t *>(&img)) {
      BOOST_LOG(error) << "Invalid macOS dummy capture frame dimensions or image type.";
      return 1;
    }

    const auto format = pixel_format_info(pixel_format);
    if (!format) {
      BOOST_LOG(error) << "Unsupported macOS dummy capture pixel format.";
      return 1;
    }

    CVPixelBufferRef pixel_buffer = nullptr;
    NSDictionary *attributes = @{
      (NSString *) kCVPixelBufferIOSurfacePropertiesKey: @ {},
    };
    const auto status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      pixel_format,
      (__bridge CFDictionaryRef) attributes,
      &pixel_buffer
    );
    if (status != kCVReturnSuccess || !pixel_buffer) {
      return fail_dummy(pixel_buffer, "Failed to create macOS dummy capture frame.");
    }

    const auto lock_status = CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    if (lock_status != kCVReturnSuccess) {
      return fail_dummy(pixel_buffer, "Failed to lock macOS dummy capture frame.");
    }
    const auto initialized = fill_black(pixel_buffer, *format);
    const auto unlock_status = CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    if (!initialized || unlock_status != kCVReturnSuccess) {
      return fail_dummy(pixel_buffer, "Failed to initialize macOS dummy capture frame.");
    }

    CMVideoFormatDescriptionRef format_description = nullptr;
    CMSampleBufferRef sample_buffer = nullptr;
    CMSampleTimingInfo timing {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    const auto format_status = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault,
      pixel_buffer,
      &format_description
    );
    const auto sample_status = format_status == noErr ? CMSampleBufferCreateForImageBuffer(
                                                          kCFAllocatorDefault,
                                                          pixel_buffer,
                                                          true,
                                                          nullptr,
                                                          nullptr,
                                                          format_description,
                                                          &timing,
                                                          &sample_buffer
                                                        ) :
                                                        format_status;
    if (format_description) {
      CFRelease(format_description);
    }
    if (sample_status != noErr || !sample_buffer) {
      if (sample_buffer) {
        CFRelease(sample_buffer);
      }
      return fail_dummy(pixel_buffer, "Failed to wrap macOS dummy capture frame.");
    }

    const auto assigned = assign(sample_buffer, img);
    CFRelease(sample_buffer);
    CVPixelBufferRelease(pixel_buffer);
    if (!assigned) {
      BOOST_LOG(error) << "macOS dummy capture frame has no usable pixel buffer.";
      return 1;
    }

    return 0;
  }
}  // namespace platf::macos_capture_image
