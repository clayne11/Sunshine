/**
 * @file tests/unit/platform/macos/test_capture_image.mm
 * @brief Unit tests for src/platform/macos/capture_image.*.
 */

// Only compile these tests on macOS.
#ifdef __APPLE__

  // test includes
  #include "../../../tests_common.h"

  // platform includes
  #import <CoreMedia/CoreMedia.h>
  #import <CoreVideo/CoreVideo.h>
  #import <Foundation/Foundation.h>

  // standard includes
  #include <cstddef>
  #include <cstdint>
  #include <cstring>
  #include <string>

  // local includes
  #include <src/platform/macos/av_img_t.h>
  #include <src/platform/macos/capture_image.h>

namespace {
  constexpr int kImageWidth = 16;
  constexpr int kImageHeight = 8;

  /**
   * @brief Create an IOSurface-backed CoreVideo pixel buffer for a test.
   *
   * @param width Pixel width.
   * @param height Pixel height.
   * @param pixel_format CoreVideo pixel format.
   * @return Newly retained pixel buffer, or null when the format is unavailable.
   */
  CVPixelBufferRef make_pixel_buffer(int width, int height, OSType pixel_format) {
    NSDictionary *attributes = @{
      (NSString *) kCVPixelBufferIOSurfacePropertiesKey: @ {},
    };
    CVPixelBufferRef pixel_buffer = nullptr;
    const auto status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      pixel_format,
      (__bridge CFDictionaryRef) attributes,
      &pixel_buffer
    );
    if (status != kCVReturnSuccess) {
      return nullptr;
    }
    return pixel_buffer;
  }

  /**
   * @brief Wrap a test pixel buffer in a CoreMedia sample buffer.
   *
   * @param pixel_buffer Pixel buffer to wrap.
   * @return Newly retained sample buffer, or null on failure.
   */
  CMSampleBufferRef make_sample_buffer(CVPixelBufferRef pixel_buffer) {
    if (!pixel_buffer) {
      return nullptr;
    }

    CMVideoFormatDescriptionRef format_description = nullptr;
    const auto format_status = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault,
      pixel_buffer,
      &format_description
    );
    if (format_status != noErr || !format_description) {
      return nullptr;
    }

    CMSampleBufferRef sample_buffer = nullptr;
    CMSampleTimingInfo timing {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    const auto sample_status = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault,
      pixel_buffer,
      true,
      nullptr,
      nullptr,
      format_description,
      &timing,
      &sample_buffer
    );
    CFRelease(format_description);
    if (sample_status != noErr) {
      if (sample_buffer) {
        CFRelease(sample_buffer);
      }
      return nullptr;
    }
    return sample_buffer;
  }

  /**
   * @brief Check every byte in a pixel-buffer plane.
   *
   * @param pixel_buffer Locked pixel buffer.
   * @param plane Plane index.
   * @param expected Expected byte value.
   */
  void expect_plane_bytes(CVPixelBufferRef pixel_buffer, size_t plane, uint8_t expected) {
    ASSERT_NE(pixel_buffer, nullptr);
    ASSERT_LT(plane, CVPixelBufferGetPlaneCount(pixel_buffer));
    auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
    const auto row_bytes = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);
    const auto row_count = CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
    ASSERT_NE(base, nullptr);
    ASSERT_GT(row_bytes, 0U);
    ASSERT_GT(row_count, 0U);
    for (size_t row = 0; row < row_count; ++row) {
      for (size_t offset = 0; offset < row_bytes; ++offset) {
        EXPECT_EQ(base[row * row_bytes + offset], expected)
          << "plane=" << plane << " row=" << row << " offset=" << offset;
      }
    }
  }

  /**
   * @brief Check every 16-bit word in a pixel-buffer plane.
   *
   * @param pixel_buffer Locked pixel buffer.
   * @param plane Plane index.
   * @param expected Expected native-endian word value.
   */
  void expect_plane_words(CVPixelBufferRef pixel_buffer, size_t plane, uint16_t expected) {
    ASSERT_NE(pixel_buffer, nullptr);
    ASSERT_LT(plane, CVPixelBufferGetPlaneCount(pixel_buffer));
    auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
    const auto row_bytes = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);
    const auto row_count = CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
    ASSERT_NE(base, nullptr);
    ASSERT_GT(row_bytes, 0U);
    ASSERT_EQ(row_bytes % sizeof(expected), 0U);
    ASSERT_GT(row_count, 0U);
    for (size_t row = 0; row < row_count; ++row) {
      for (size_t offset = 0; offset < row_bytes; offset += sizeof(expected)) {
        uint16_t actual = 0;
        std::memcpy(&actual, base + row * row_bytes + offset, sizeof(actual));
        EXPECT_EQ(actual, expected)
          << "plane=" << plane << " row=" << row << " offset=" << offset;
      }
    }
  }

  /**
   * @brief Parameters for black dummy-frame coverage.
   */
  struct DummyFormat {
    OSType pixel_format;  ///< CoreVideo pixel format under test.
    bool planar;  ///< Whether the format has separate luma and chroma planes.
    bool ten_bit;  ///< Whether plane values are 10-bit words in 16-bit storage.
    bool full_range;  ///< Whether luma black is the full-range zero value.
    const char *name;  ///< Stable gtest parameter name.
  };

  class CaptureImageTest: public ::testing::Test {
  protected:
    void SetUp() override {
      autorelease_pool = [[NSAutoreleasePool alloc] init];
    }

    void TearDown() override {
      [autorelease_pool drain];
      autorelease_pool = nil;
    }

    NSAutoreleasePool *autorelease_pool {};  ///< Objective-C autorelease pool for CoreVideo setup.
  };

  class DummyImageTest: public CaptureImageTest, public ::testing::WithParamInterface<DummyFormat> {};

  TEST_F(CaptureImageTest, AssignRejectsNullAndSampleWithoutImageBuffer) {
    platf::av_img_t image;
    image.width = 17;
    image.height = 19;
    image.row_pitch = 23;
    image.pixel_pitch = 2;

    EXPECT_FALSE(platf::macos_capture_image::assign(nullptr, image));
    EXPECT_EQ(image.width, 17);
    EXPECT_EQ(image.height, 19);
    EXPECT_EQ(image.row_pitch, 23);
    EXPECT_EQ(image.pixel_pitch, 2);

    CMSampleBufferRef sample_buffer = nullptr;
    ASSERT_EQ(
      CMSampleBufferCreate(
        kCFAllocatorDefault,
        nullptr,
        true,
        nullptr,
        nullptr,
        nullptr,
        0,
        0,
        nullptr,
        0,
        nullptr,
        &sample_buffer
      ),
      noErr
    );
    ASSERT_NE(sample_buffer, nullptr);
    EXPECT_FALSE(platf::macos_capture_image::assign(sample_buffer, image));
    EXPECT_EQ(image.width, 17);
    CFRelease(sample_buffer);
  }

  TEST_F(CaptureImageTest, AssignRetainsBothWrappersAndUpdatesMetadata) {
    CVPixelBufferRef first_pixel_buffer = make_pixel_buffer(kImageWidth, kImageHeight, kCVPixelFormatType_32BGRA);
    ASSERT_NE(first_pixel_buffer, nullptr);
    ASSERT_NE(CVPixelBufferGetIOSurface(first_pixel_buffer), nullptr);
    CMSampleBufferRef first_sample_buffer = make_sample_buffer(first_pixel_buffer);
    ASSERT_NE(first_sample_buffer, nullptr);

    platf::av_img_t image;
    ASSERT_TRUE(platf::macos_capture_image::assign(first_sample_buffer, image));
    ASSERT_NE(image.sample_buffer, nullptr);
    ASSERT_NE(image.pixel_buffer, nullptr);
    const auto old_sample = image.sample_buffer;
    const auto old_pixel = image.pixel_buffer;

    CVPixelBufferRef second_pixel_buffer = make_pixel_buffer(kImageWidth + 4, kImageHeight + 2, kCVPixelFormatType_32BGRA);
    ASSERT_NE(second_pixel_buffer, nullptr);
    CMSampleBufferRef second_sample_buffer = make_sample_buffer(second_pixel_buffer);
    ASSERT_NE(second_sample_buffer, nullptr);

    ASSERT_TRUE(platf::macos_capture_image::assign(second_sample_buffer, image));
    EXPECT_NE(image.sample_buffer, old_sample);
    EXPECT_NE(image.pixel_buffer, old_pixel);
    EXPECT_EQ(image.width, kImageWidth + 4);
    EXPECT_EQ(image.height, kImageHeight + 2);
    EXPECT_EQ(image.row_pitch, static_cast<int>(CVPixelBufferGetBytesPerRow(second_pixel_buffer)));
    EXPECT_EQ(image.pixel_pitch, image.row_pitch / image.width);

    ASSERT_NE(old_sample->buf, nullptr);
    ASSERT_NE(old_pixel->buf, nullptr);
    EXPECT_NE(old_pixel->data(), nullptr);

    CFRelease(second_sample_buffer);
    CVPixelBufferRelease(second_pixel_buffer);
    CFRelease(first_sample_buffer);
    CVPixelBufferRelease(first_pixel_buffer);
    EXPECT_NE(old_sample->buf, nullptr);
    EXPECT_NE(old_pixel->data(), nullptr);
  }

  TEST_F(CaptureImageTest, MakeDummyRejectsInvalidDimensionsAndFormats) {
    platf::av_img_t image;
    EXPECT_NE(platf::macos_capture_image::make_dummy(image, 0, kImageHeight, kCVPixelFormatType_32BGRA), 0);
    EXPECT_NE(platf::macos_capture_image::make_dummy(image, -1, kImageHeight, kCVPixelFormatType_32BGRA), 0);
    EXPECT_NE(platf::macos_capture_image::make_dummy(image, kImageWidth, 0, kCVPixelFormatType_32BGRA), 0);
    EXPECT_NE(platf::macos_capture_image::make_dummy(image, kImageWidth, kImageHeight, kCVPixelFormatType_OneComponent8), 0);

    platf::img_t plain_image;
    EXPECT_NE(platf::macos_capture_image::make_dummy(plain_image, kImageWidth, kImageHeight, kCVPixelFormatType_32BGRA), 0);
  }

  TEST_P(DummyImageTest, CreatesIosurfaceBackedBlackBuffer) {
    const auto &format = GetParam();
    CVPixelBufferRef probe = make_pixel_buffer(kImageWidth, kImageHeight, format.pixel_format);
    if (!probe) {
      GTEST_SKIP() << "CoreVideo format is unavailable on this macOS host";
    }
    ASSERT_NE(CVPixelBufferGetIOSurface(probe), nullptr);
    ASSERT_EQ(CVPixelBufferLockBaseAddress(probe, 0), kCVReturnSuccess);
    if (format.planar) {
      ASSERT_GE(CVPixelBufferGetPlaneCount(probe), 2U);
      ASSERT_NE(CVPixelBufferGetBaseAddressOfPlane(probe, 0), nullptr);
    } else {
      ASSERT_NE(CVPixelBufferGetBaseAddress(probe), nullptr);
    }
    ASSERT_EQ(CVPixelBufferUnlockBaseAddress(probe, 0), kCVReturnSuccess);
    CVPixelBufferRelease(probe);

    platf::av_img_t image;
    ASSERT_EQ(platf::macos_capture_image::make_dummy(image, kImageWidth, kImageHeight, format.pixel_format), 0);
    ASSERT_NE(image.sample_buffer, nullptr);
    ASSERT_NE(image.pixel_buffer, nullptr);
    auto *pixel_buffer = image.pixel_buffer->buf;
    ASSERT_NE(pixel_buffer, nullptr);
    EXPECT_EQ(CVPixelBufferGetPixelFormatType(pixel_buffer), format.pixel_format);
    EXPECT_EQ(CVPixelBufferGetWidth(pixel_buffer), static_cast<size_t>(kImageWidth));
    EXPECT_EQ(CVPixelBufferGetHeight(pixel_buffer), static_cast<size_t>(kImageHeight));
    EXPECT_NE(CVPixelBufferGetIOSurface(pixel_buffer), nullptr);
    EXPECT_NE(image.data, nullptr);
    EXPECT_EQ(image.pixel_pitch, image.row_pitch / image.width);

    if (!format.planar) {
      auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pixel_buffer));
      ASSERT_NE(base, nullptr);
      const auto row_bytes = CVPixelBufferGetBytesPerRow(pixel_buffer);
      for (size_t row = 0; row < CVPixelBufferGetHeight(pixel_buffer); ++row) {
        for (size_t offset = 0; offset < row_bytes; ++offset) {
          EXPECT_EQ(base[row * row_bytes + offset], 0);
        }
      }
    } else if (!format.ten_bit) {
      expect_plane_bytes(pixel_buffer, 0, format.full_range ? 0x00 : 0x10);
      expect_plane_bytes(pixel_buffer, 1, 0x80);
    } else {
      expect_plane_words(pixel_buffer, 0, static_cast<uint16_t>((format.full_range ? 0 : 64) << 6));
      expect_plane_words(pixel_buffer, 1, static_cast<uint16_t>(512 << 6));
    }
  }

  INSTANTIATE_TEST_SUITE_P(
    CoreVideoFormats,
    DummyImageTest,
    ::testing::Values(
      DummyFormat {kCVPixelFormatType_32BGRA, false, false, false, "BGRA"},
      DummyFormat {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, true, false, false, "NV12VideoRange"},
      DummyFormat {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, true, false, true, "NV12FullRange"},
      DummyFormat {kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, true, true, false, "P010VideoRange"},
      DummyFormat {kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, true, true, true, "P010FullRange"}
    ),
    [](const ::testing::TestParamInfo<DummyFormat> &info) {
      return std::string {info.param.name};
    }
  );
}  // namespace

#endif  // __APPLE__
