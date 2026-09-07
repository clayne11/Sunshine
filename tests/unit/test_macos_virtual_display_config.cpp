/**
 * @file tests/unit/test_macos_virtual_display_config.cpp
 * @brief Validate virtual-display requests without touching the desktop.
 */
#include "../tests_common.h"
#include "src/config.h"
#include "src/display_device.h"
#include "src/rtsp.h"

TEST(MacOSVirtualDisplayConfig, DisabledFeatureDoesNotCreateDisplay) {
  config::video_t video_config {};
  rtsp_stream::launch_session_t session {};
  // Disabled must remain a no-op even for absent session dimensions.
  EXPECT_TRUE(display_device::create_virtual_display(video_config, session));
}

TEST(MacOSVirtualDisplayConfig, RejectsInvalidModesBeforeChangingDisplays) {
  config::video_t video_config {};
  video_config.virtual_display = true;
  video_config.virtual_display_exclusive = true;
  const int invalid_modes[][3] = {
    {0, 1668, 60},
    {-1, 1668, 60},
    {2420, 0, 60},
    {2420, -1, 60},
    {16385, 1668, 60},
    {2420, 16385, 60},
    {2420, 1668, 0},
    {2420, 1668, -1},
    {2420, 1668, 241}
  };
  for (const auto &mode : invalid_modes) {
    rtsp_stream::launch_session_t session {};
    session.width = mode[0];
    session.height = mode[1];
    session.fps = mode[2];
    EXPECT_FALSE(display_device::create_virtual_display(video_config, session))
      << mode[0] << 'x' << mode[1] << '@' << mode[2];
  }
}
