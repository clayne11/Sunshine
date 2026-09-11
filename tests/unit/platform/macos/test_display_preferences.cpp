/**
 * @file tests/unit/platform/macos/test_display_preferences.cpp
 * @brief Unit tests for src/platform/macos/display_preferences.*.
 */
#ifdef __APPLE__

  #include <chrono>
  #include <filesystem>
  #include <fstream>
  #include <gtest/gtest.h>
  #include <src/platform/macos/display_preferences.h>
  #include <string>
  #include <unistd.h>
  #include <vector>

namespace {
  /**
   * @brief Create a complete requested tuple for preference tests.
   * @param width Logical width.
   * @param height Logical height.
   * @param refresh_rate Refresh rate.
   * @return Requested mode.
   */
  macos_display_requested_mode_t requested_mode(uint32_t width, uint32_t height, uint32_t refresh_rate) {
    return macos_display_requested_mode_t {width, height, refresh_rate};
  }

  /**
   * @brief Create a complete observed mode for preference tests.
   * @param logical_width Logical width.
   * @param logical_height Logical height.
   * @param pixel_width Backing pixel width.
   * @param pixel_height Backing pixel height.
   * @param refresh_rate Refresh rate.
   * @param hidpi Whether the mode is HiDPI.
   * @return Observed mode.
   */
  macos_display_mode_t observed_mode(
    uint32_t logical_width,
    uint32_t logical_height,
    uint32_t pixel_width,
    uint32_t pixel_height,
    double refresh_rate,
    bool hidpi
  ) {
    return macos_display_mode_t {
      logical_width,
      logical_height,
      pixel_width,
      pixel_height,
      refresh_rate,
      hidpi
    };
  }

  /**
   * @brief Test fixture providing an isolated preference profile directory.
   */
  class display_preferences_test: public ::testing::Test {
  protected:
    void SetUp() override {
      profile_directory = std::filesystem::temp_directory_path() /
                          ("sunshine-display-preferences-" + std::to_string(getpid()) + "-" +
                           std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
      ASSERT_TRUE(std::filesystem::create_directories(profile_directory));
    }

    void TearDown() override {
      std::error_code error;
      std::filesystem::remove_all(profile_directory, error);
    }

    std::filesystem::path profile_directory;  ///< Isolated directory for one test.
  };

  constexpr char CLIENT_A[] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  constexpr char CLIENT_B[] = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

  /**
   * @brief Get the current per-client, per-resolution preference path.
   * @param profile_directory Isolated preference directory.
   * @param client Certificate fingerprint.
   * @param requested Requested logical dimensions.
   * @return Current preference path.
   */
  std::filesystem::path current_preference_file(
    const std::filesystem::path &profile_directory,
    const char *client,
    const macos_display_requested_mode_t &requested
  ) {
    return profile_directory /
           ("display-mode-" + std::string {client} + "-" + std::to_string(requested.width) + "x" + std::to_string(requested.height) + ".json");
  }

  /**
   * @brief Get the legacy per-client preference path.
   * @param profile_directory Isolated preference directory.
   * @param client Certificate fingerprint.
   * @return Legacy preference path.
   */
  std::filesystem::path legacy_preference_file(const std::filesystem::path &profile_directory, const char *client) {
    return profile_directory / ("display-mode-" + std::string {client} + ".json");
  }
}  // namespace

TEST_F(display_preferences_test, SavesAndLoadsCanonicalHiDpiMode) {
  const macos_display_requested_mode_t requested {requested_mode(2420, 1668, 30)};
  const macos_display_preference_t expected {
    requested,
    observed_mode(1210, 834, 2420, 1668, 30.0, true)
  };

  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &expected));

  macos_display_preference_t actual {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &requested, &actual));
  EXPECT_EQ(actual.requested.width, expected.requested.width);
  EXPECT_EQ(actual.requested.height, expected.requested.height);
  EXPECT_EQ(actual.requested.refresh_rate, expected.requested.refresh_rate);
  EXPECT_EQ(actual.mode.logical_width, expected.mode.logical_width);
  EXPECT_EQ(actual.mode.logical_height, expected.mode.logical_height);
  EXPECT_EQ(actual.mode.pixel_width, expected.mode.pixel_width);
  EXPECT_EQ(actual.mode.pixel_height, expected.mode.pixel_height);
  EXPECT_DOUBLE_EQ(actual.mode.refresh_rate, expected.mode.refresh_rate);
  EXPECT_EQ(actual.mode.hidpi, expected.mode.hidpi);

  const auto file = current_preference_file(profile_directory, CLIENT_A, requested);
  EXPECT_TRUE(std::filesystem::exists(file));
}

TEST_F(display_preferences_test, RequestedTupleMismatchDoesNotLoadOverride) {
  const macos_display_preference_t expected {
    requested_mode(1920, 1080, 60),
    observed_mode(1920, 1080, 1920, 1080, 60.0, false)
  };
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &expected));

  const auto changed_request = requested_mode(2560, 1440, 60);
  macos_display_preference_t actual {};
  EXPECT_FALSE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &changed_request, &actual));
}

TEST_F(display_preferences_test, KeepsIndependentClientEntries) {
  const macos_display_preference_t first {
    requested_mode(1920, 1080, 60),
    observed_mode(1920, 1080, 1920, 1080, 60.0, false)
  };
  const macos_display_preference_t second {
    requested_mode(1280, 720, 30),
    observed_mode(640, 360, 1280, 720, 30.0, true)
  };
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &first));
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_B, &second));

  macos_display_preference_t loaded_first {};
  macos_display_preference_t loaded_second {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &first.requested, &loaded_first));
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_B, &second.requested, &loaded_second));
  macos_display_preference_t cross_client {};
  EXPECT_FALSE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_B, &first.requested, &cross_client));
  EXPECT_EQ(loaded_first.mode.logical_width, first.mode.logical_width);
  EXPECT_EQ(loaded_second.mode.logical_width, second.mode.logical_width);
  EXPECT_NE(loaded_first.mode.logical_width, loaded_second.mode.logical_width);
}

TEST_F(display_preferences_test, KeepsIndependentResolutionEntriesForOneClient) {
  const macos_display_preference_t first {
    requested_mode(1920, 1080, 60),
    observed_mode(1920, 1080, 1920, 1080, 60.0, false)
  };
  const macos_display_preference_t second {
    requested_mode(1280, 720, 60),
    observed_mode(640, 360, 1280, 720, 60.0, true)
  };
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &first));
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &second));

  macos_display_preference_t loaded_first {};
  macos_display_preference_t loaded_second {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &first.requested, &loaded_first));
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &second.requested, &loaded_second));
  EXPECT_EQ(loaded_first.mode.logical_width, first.mode.logical_width);
  EXPECT_EQ(loaded_second.mode.logical_width, second.mode.logical_width);
  EXPECT_TRUE(std::filesystem::exists(current_preference_file(profile_directory, CLIENT_A, first.requested)));
  EXPECT_TRUE(std::filesystem::exists(current_preference_file(profile_directory, CLIENT_A, second.requested)));
}

TEST_F(display_preferences_test, RefreshRateIsNotPartOfMappingKey) {
  const auto saved_request = requested_mode(1920, 1080, 60);
  const macos_display_preference_t saved {
    saved_request,
    observed_mode(960, 540, 1920, 1080, 60.0, true)
  };
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &saved));

  const auto changed_request = requested_mode(1920, 1080, 30);
  macos_display_preference_t loaded {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &changed_request, &loaded));
  EXPECT_EQ(loaded.requested.width, changed_request.width);
  EXPECT_EQ(loaded.requested.height, changed_request.height);
  EXPECT_EQ(loaded.requested.refresh_rate, changed_request.refresh_rate);
  EXPECT_EQ(loaded.mode.logical_width, saved.mode.logical_width);
  EXPECT_EQ(loaded.mode.logical_height, saved.mode.logical_height);
  EXPECT_EQ(loaded.mode.pixel_width, saved.mode.pixel_width);
  EXPECT_EQ(loaded.mode.pixel_height, saved.mode.pixel_height);
  EXPECT_EQ(loaded.mode.hidpi, saved.mode.hidpi);
  EXPECT_DOUBLE_EQ(loaded.mode.refresh_rate, static_cast<double>(changed_request.refresh_rate));
}

TEST_F(display_preferences_test, ExplicitModeChangeUpdatesOnlyOriginalResolution) {
  const macos_display_preference_t original {
    requested_mode(1920, 1080, 60),
    observed_mode(1920, 1080, 1920, 1080, 60.0, false)
  };
  const macos_display_preference_t other_resolution {
    requested_mode(1280, 720, 60),
    observed_mode(1280, 720, 1280, 720, 60.0, false)
  };
  const macos_display_preference_t changed {
    original.requested,
    observed_mode(960, 540, 1920, 1080, 60.0, true)
  };
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &original));
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &other_resolution));
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &changed));

  macos_display_preference_t loaded_original {};
  macos_display_preference_t loaded_other_resolution {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &original.requested, &loaded_original));
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &other_resolution.requested, &loaded_other_resolution));
  EXPECT_EQ(loaded_original.mode.logical_width, changed.mode.logical_width);
  EXPECT_EQ(loaded_original.mode.logical_height, changed.mode.logical_height);
  EXPECT_EQ(loaded_original.mode.hidpi, changed.mode.hidpi);
  EXPECT_EQ(loaded_other_resolution.mode.logical_width, other_resolution.mode.logical_width);
  EXPECT_EQ(loaded_other_resolution.mode.logical_height, other_resolution.mode.logical_height);
  EXPECT_EQ(loaded_other_resolution.mode.hidpi, other_resolution.mode.hidpi);
}

TEST_F(display_preferences_test, ReadsLegacyEntryForChangedRefreshRateWithoutMigratingIt) {
  const auto stored_request = requested_mode(1920, 1080, 60);
  const auto legacy_file = legacy_preference_file(profile_directory, CLIENT_A);
  std::ofstream output {legacy_file};
  ASSERT_TRUE(output);
  output << "{\"version\":1,\"certificate_fingerprint\":\"" << CLIENT_A
         << "\",\"requested\":{\"width\":" << stored_request.width << ",\"height\":" << stored_request.height
         << ",\"refresh_rate\":" << stored_request.refresh_rate
         << "},\"mode\":{\"logical_width\":960,\"logical_height\":540,\"pixel_width\":1920,\"pixel_height\":1080,\"refresh_rate\":60.0,\"hidpi\":true}}\n";
  output.close();

  const auto changed_request = requested_mode(1920, 1080, 30);
  macos_display_preference_t loaded {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &changed_request, &loaded));
  EXPECT_EQ(loaded.requested.refresh_rate, changed_request.refresh_rate);
  EXPECT_EQ(loaded.mode.logical_width, 960U);
  EXPECT_EQ(loaded.mode.logical_height, 540U);
  EXPECT_EQ(loaded.mode.hidpi, true);
  EXPECT_DOUBLE_EQ(loaded.mode.refresh_rate, static_cast<double>(changed_request.refresh_rate));
  EXPECT_TRUE(std::filesystem::exists(legacy_file));
  EXPECT_FALSE(std::filesystem::exists(current_preference_file(profile_directory, CLIENT_A, changed_request)));
}

TEST_F(display_preferences_test, InvalidCurrentEntryDoesNotFallbackToLegacyEntry) {
  const auto requested = requested_mode(1920, 1080, 30);
  const auto legacy_file = legacy_preference_file(profile_directory, CLIENT_A);
  std::ofstream legacy_output {legacy_file};
  ASSERT_TRUE(legacy_output);
  legacy_output << "{\"version\":1,\"certificate_fingerprint\":\"" << CLIENT_A
                << "\",\"requested\":{\"width\":1920,\"height\":1080,\"refresh_rate\":60},\"mode\":{\"logical_width\":960,\"logical_height\":540,\"pixel_width\":1920,\"pixel_height\":1080,\"refresh_rate\":60.0,\"hidpi\":true}}\n";
  legacy_output.close();

  const auto current_file = current_preference_file(profile_directory, CLIENT_A, requested);
  std::ofstream current_output {current_file};
  ASSERT_TRUE(current_output);
  current_output << "{\"version\":1,\"certificate_fingerprint\":\"wrong\"}\n";
  current_output.close();

  macos_display_preference_t loaded {};
  EXPECT_FALSE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &requested, &loaded));
}

TEST_F(display_preferences_test, RejectsLegacyEntryWithInvalidRefreshRate) {
  const auto requested = requested_mode(1920, 1080, 30);
  const auto legacy_file = legacy_preference_file(profile_directory, CLIENT_A);
  std::ofstream output {legacy_file};
  ASSERT_TRUE(output);
  output << "{\"version\":1,\"certificate_fingerprint\":\"" << CLIENT_A
         << "\",\"requested\":{\"width\":1920,\"height\":1080,\"refresh_rate\":0},\"mode\":{\"logical_width\":960,\"logical_height\":540,\"pixel_width\":1920,\"pixel_height\":1080,\"refresh_rate\":60.0,\"hidpi\":true}}\n";
  output.close();

  macos_display_preference_t loaded {};
  EXPECT_FALSE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &requested, &loaded));
}

TEST_F(display_preferences_test, RejectsInvalidValuesAndMalformedFiles) {
  const macos_display_preference_t invalid_dimensions {
    requested_mode(1920, 1080, 60),
    observed_mode(0, 1080, 1920, 1080, 60.0, true)
  };
  EXPECT_FALSE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &invalid_dimensions));
  EXPECT_FALSE(macos_display_preferences_save(profile_directory.c_str(), "../unsafe", &invalid_dimensions));

  const auto file = current_preference_file(profile_directory, CLIENT_A, invalid_dimensions.requested);
  std::ofstream output {file};
  output << "{\"version\":1,\"certificate_fingerprint\":\"wrong\"}\n";
  output.close();

  const auto requested = requested_mode(1920, 1080, 60);
  macos_display_preference_t actual {};
  EXPECT_FALSE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &requested, &actual));
}

TEST_F(display_preferences_test, ReplacesEntryAtomically) {
  const macos_display_preference_t first {
    requested_mode(1920, 1080, 60),
    observed_mode(1920, 1080, 1920, 1080, 60.0, false)
  };
  const macos_display_preference_t second {
    first.requested,
    observed_mode(960, 540, 1920, 1080, 60.0, true)
  };
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &first));
  EXPECT_TRUE(macos_display_preferences_save(profile_directory.c_str(), CLIENT_A, &second));

  macos_display_preference_t actual {};
  EXPECT_TRUE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &first.requested, &actual));
  EXPECT_EQ(actual.mode.logical_width, second.mode.logical_width);
  EXPECT_EQ(actual.mode.logical_height, second.mode.logical_height);

  for (const auto &entry : std::filesystem::directory_iterator(profile_directory)) {
    EXPECT_EQ(entry.path().extension(), ".json");
  }
}

TEST_F(display_preferences_test, RejectsUnsignedValuesBeforeNarrowing) {
  const auto requested = requested_mode(1920, 1080, 60);
  const auto file = current_preference_file(profile_directory, CLIENT_A, requested);
  macos_display_preference_t actual {};
  const std::vector<std::string> invalid_documents {
    "{\"version\":4294967297,\"certificate_fingerprint\":\"" + std::string {CLIENT_A} + "\",\"requested\":{\"width\":1920,\"height\":1080,\"refresh_rate\":60},\"mode\":{\"logical_width\":1920,\"logical_height\":1080,\"pixel_width\":1920,\"pixel_height\":1080,\"refresh_rate\":60,\"hidpi\":false}}",
    "{\"version\":1,\"certificate_fingerprint\":\"" + std::string {CLIENT_A} + "\",\"requested\":{\"width\":4294969216,\"height\":1080,\"refresh_rate\":60},\"mode\":{\"logical_width\":1920,\"logical_height\":1080,\"pixel_width\":1920,\"pixel_height\":1080,\"refresh_rate\":60,\"hidpi\":false}}",
    "{\"version\":1,\"certificate_fingerprint\":\"" + std::string {CLIENT_A} + "\",\"requested\":{\"width\":1920,\"height\":1080,\"refresh_rate\":60},\"mode\":{\"logical_width\":1920,\"logical_height\":1080,\"pixel_width\":4294969216,\"pixel_height\":1080,\"refresh_rate\":60,\"hidpi\":false}}"
  };

  for (const auto &document : invalid_documents) {
    std::ofstream output {file, std::ios::trunc};
    ASSERT_TRUE(output);
    output << document << '\n';
    output.close();
    EXPECT_FALSE(macos_display_preferences_load(profile_directory.c_str(), CLIENT_A, &requested, &actual));
  }
}

#endif  // __APPLE__
