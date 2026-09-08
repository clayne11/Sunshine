/**
 * @file src/platform/macos/display_preferences.cpp
 * @brief Per-client virtual-display mode persistence for macOS.
 */
#include "display_preferences.h"

#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include <string>
#include <string_view>
#include <unistd.h>

namespace {
  using json = nlohmann::json;

  constexpr unsigned int PREFERENCE_SCHEMA_VERSION {1};  ///< Current on-disk preference schema.

  /**
   * @brief Check whether a certificate fingerprint is a safe SHA-256 key.
   * @param fingerprint Candidate fingerprint.
   * @return True when the value contains exactly 64 hexadecimal characters.
   */
  bool is_fingerprint(std::string_view fingerprint) {
    if (fingerprint.size() != 64) {
      return false;
    }
    for (const unsigned char character : fingerprint) {
      if (!std::isxdigit(character)) {
        return false;
      }
    }
    return true;
  }

  /**
   * @brief Convert a valid fingerprint to a canonical lowercase representation.
   * @param fingerprint Valid hexadecimal fingerprint.
   * @return Lowercase fingerprint.
   */
  std::string canonical_fingerprint(std::string_view fingerprint) {
    std::string result {fingerprint};
    for (char &character : result) {
      character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return result;
  }

  /**
   * @brief Check whether a requested Moonlight mode is bounded and complete.
   * @param mode Requested mode to validate.
   * @return True when all fields are within the supported bounds.
   */
  bool valid_requested_mode(const macos_display_requested_mode_t &mode) {
    return mode.width > 0 && mode.width <= MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION &&
           mode.height > 0 && mode.height <= MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION &&
           mode.refresh_rate > 0 && mode.refresh_rate <= MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE;
  }

  /**
   * @brief Check whether an observed CoreGraphics mode is safe to persist.
   * @param mode Observed mode to validate.
   * @return True when dimensions, scale, and refresh rate are coherent.
   */
  bool valid_display_mode(const macos_display_mode_t &mode) {
    const bool dimensions_are_scaled = mode.pixel_width != mode.logical_width || mode.pixel_height != mode.logical_height;
    return mode.logical_width > 0 && mode.logical_width <= MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION &&
           mode.logical_height > 0 && mode.logical_height <= MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION &&
           mode.pixel_width > 0 && mode.pixel_width <= MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION &&
           mode.pixel_height > 0 && mode.pixel_height <= MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION &&
           mode.pixel_width >= mode.logical_width && mode.pixel_height >= mode.logical_height &&
           std::isfinite(mode.refresh_rate) && mode.refresh_rate > 0.0 && mode.refresh_rate <= static_cast<double>(MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE) &&
           mode.hidpi == dimensions_are_scaled;
  }

  /**
   * @brief Check whether two requested tuples identify the same client request.
   * @param lhs First requested tuple.
   * @param rhs Second requested tuple.
   * @return True when all tuple fields match.
   */
  bool same_requested_mode(const macos_display_requested_mode_t &lhs, const macos_display_requested_mode_t &rhs) {
    return lhs.width == rhs.width && lhs.height == rhs.height && lhs.refresh_rate == rhs.refresh_rate;
  }

  /**
   * @brief Build the per-client preference filename.
   * @param profile_directory Directory containing preference files.
   * @param fingerprint Canonical client certificate fingerprint.
   * @return Final preference path.
   */
  std::filesystem::path preference_path(const char *profile_directory, std::string_view fingerprint) {
    return std::filesystem::path {profile_directory} / ("display-mode-" + std::string {fingerprint} + ".json");
  }

  /**
   * @brief Add a requested mode to a JSON object.
   * @param mode Requested mode to serialize.
   * @return JSON representation.
   */
  json requested_to_json(const macos_display_requested_mode_t &mode) {
    return json {
      {"width", mode.width},
      {"height", mode.height},
      {"refresh_rate", mode.refresh_rate}
    };
  }

  /**
   * @brief Add an observed mode to a JSON object.
   * @param mode Observed mode to serialize.
   * @return JSON representation.
   */
  json mode_to_json(const macos_display_mode_t &mode) {
    return json {
      {"logical_width", mode.logical_width},
      {"logical_height", mode.logical_height},
      {"pixel_width", mode.pixel_width},
      {"pixel_height", mode.pixel_height},
      {"refresh_rate", mode.refresh_rate},
      {"hidpi", mode.hidpi}
    };
  }

  /**
   * @brief Parse a requested mode using the strict preference schema.
   * @param node JSON node to parse.
   * @param mode Receives the parsed mode.
   * @return True when the node has exactly the expected fields and values.
   */
  bool requested_from_json(const json &node, macos_display_requested_mode_t &mode) {
    if (!node.is_object() || node.size() != 3 || !node.contains("width") || !node.contains("height") || !node.contains("refresh_rate") || !node.at("width").is_number_unsigned() || !node.at("height").is_number_unsigned() || !node.at("refresh_rate").is_number_unsigned()) {
      return false;
    }

    try {
      const auto width = node.at("width").get<uint64_t>();
      const auto height = node.at("height").get<uint64_t>();
      const auto refresh_rate = node.at("refresh_rate").get<uint64_t>();
      if (width > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || height > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || refresh_rate > MACOS_DISPLAY_PREFERENCE_MAX_REFRESH_RATE) {
        return false;
      }
      mode.width = static_cast<uint32_t>(width);
      mode.height = static_cast<uint32_t>(height);
      mode.refresh_rate = static_cast<uint32_t>(refresh_rate);
    } catch (const json::exception &) {
      return false;
    }
    return valid_requested_mode(mode);
  }

  /**
   * @brief Parse an observed mode using the strict preference schema.
   * @param node JSON node to parse.
   * @param mode Receives the parsed mode.
   * @return True when the node has exactly the expected fields and values.
   */
  bool mode_from_json(const json &node, macos_display_mode_t &mode) {
    if (!node.is_object() || node.size() != 6 || !node.contains("logical_width") || !node.contains("logical_height") || !node.contains("pixel_width") || !node.contains("pixel_height") || !node.contains("refresh_rate") || !node.contains("hidpi") || !node.at("logical_width").is_number_unsigned() || !node.at("logical_height").is_number_unsigned() || !node.at("pixel_width").is_number_unsigned() || !node.at("pixel_height").is_number_unsigned() || !node.at("refresh_rate").is_number() || !node.at("hidpi").is_boolean()) {
      return false;
    }

    try {
      const auto logical_width = node.at("logical_width").get<uint64_t>();
      const auto logical_height = node.at("logical_height").get<uint64_t>();
      const auto pixel_width = node.at("pixel_width").get<uint64_t>();
      const auto pixel_height = node.at("pixel_height").get<uint64_t>();
      if (logical_width > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || logical_height > MACOS_DISPLAY_PREFERENCE_MAX_LOGICAL_DIMENSION || pixel_width > MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION || pixel_height > MACOS_DISPLAY_PREFERENCE_MAX_PIXEL_DIMENSION) {
        return false;
      }
      mode.logical_width = static_cast<uint32_t>(logical_width);
      mode.logical_height = static_cast<uint32_t>(logical_height);
      mode.pixel_width = static_cast<uint32_t>(pixel_width);
      mode.pixel_height = static_cast<uint32_t>(pixel_height);
      mode.refresh_rate = node.at("refresh_rate").get<double>();
      mode.hidpi = node.at("hidpi").get<bool>();
    } catch (const json::exception &) {
      return false;
    }
    return valid_display_mode(mode);
  }

  /**
   * @brief Write all bytes to a file descriptor.
   * @param descriptor Open output descriptor.
   * @param content Bytes to write.
   * @return True when every byte was written.
   */
  bool write_all(int descriptor, std::string_view content) {
    std::size_t offset = 0;
    while (offset < content.size()) {
      const ssize_t written = write(descriptor, content.data() + offset, content.size() - offset);
      if (written < 0) {
        if (errno == EINTR) {
          continue;
        }
        return false;
      }
      if (written == 0) {
        return false;
      }
      offset += static_cast<std::size_t>(written);
    }
    return true;
  }

  /**
   * @brief Read and parse a preference file.
   * @param path Preference file path.
   * @param fingerprint Canonical certificate fingerprint.
   * @param requested Current requested tuple.
   * @param preference Receives the parsed preference.
   * @return True when the file is valid and matches this client request.
   */
  bool read_preference(
    const std::filesystem::path &path,
    std::string_view fingerprint,
    const macos_display_requested_mode_t &requested,
    macos_display_preference_t &preference
  ) {
    std::ifstream input {path};
    if (!input) {
      return false;
    }

    try {
      const json root = json::parse(input);
      if (!root.is_object() || root.size() != 4 || !root.contains("version") || !root.contains("certificate_fingerprint") || !root.contains("requested") || !root.contains("mode") || !root.at("version").is_number_unsigned() || root.at("version").get<uint64_t>() != PREFERENCE_SCHEMA_VERSION || !root.at("certificate_fingerprint").is_string() || canonical_fingerprint(root.at("certificate_fingerprint").get<std::string>()) != fingerprint) {
        return false;
      }

      macos_display_requested_mode_t stored_requested {};
      macos_display_mode_t stored_mode {};
      if (!requested_from_json(root.at("requested"), stored_requested) || !mode_from_json(root.at("mode"), stored_mode) || !same_requested_mode(stored_requested, requested)) {
        return false;
      }

      preference.requested = stored_requested;
      preference.mode = stored_mode;
      return true;
    } catch (const json::exception &) {
      return false;
    } catch (const std::exception &) {
      return false;
    }
  }
}  // namespace

extern "C" bool macos_display_preferences_load(
  const char *profile_directory,
  const char *certificate_fingerprint,
  const macos_display_requested_mode_t *requested,
  macos_display_preference_t *preference
) {
  if (!profile_directory || !certificate_fingerprint || !requested || !preference || !*profile_directory || !is_fingerprint(certificate_fingerprint) || !valid_requested_mode(*requested)) {
    return false;
  }

  const std::string fingerprint {canonical_fingerprint(certificate_fingerprint)};
  return read_preference(preference_path(profile_directory, fingerprint), fingerprint, *requested, *preference);
}

extern "C" bool macos_display_preferences_save(
  const char *profile_directory,
  const char *certificate_fingerprint,
  const macos_display_preference_t *preference
) {
  if (!profile_directory || !certificate_fingerprint || !preference || !*profile_directory || !is_fingerprint(certificate_fingerprint) || !valid_requested_mode(preference->requested) || !valid_display_mode(preference->mode)) {
    return false;
  }

  const std::string fingerprint {canonical_fingerprint(certificate_fingerprint)};
  const std::filesystem::path directory {profile_directory};
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) {
    return false;
  }

  const std::filesystem::path destination {preference_path(profile_directory, fingerprint)};
  const auto timestamp = std::chrono::steady_clock::now().time_since_epoch().count();
  const std::filesystem::path temporary {destination.string() + ".tmp-" + std::to_string(getpid()) + "-" + std::to_string(timestamp)};
  const json root {
    {"version", PREFERENCE_SCHEMA_VERSION},
    {"certificate_fingerprint", fingerprint},
    {"requested", requested_to_json(preference->requested)},
    {"mode", mode_to_json(preference->mode)}
  };
  const std::string serialized {root.dump(2) + "\n"};

  const int descriptor = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_TRUNC, 0600);
  if (descriptor < 0) {
    return false;
  }

  bool success = write_all(descriptor, serialized);
  if (success && fsync(descriptor) != 0) {
    success = false;
  }
  if (close(descriptor) != 0) {
    success = false;
  }
  if (!success) {
    std::filesystem::remove(temporary, error);
    return false;
  }

  std::filesystem::rename(temporary, destination, error);
  if (error) {
    std::filesystem::remove(temporary, error);
    return false;
  }
  return true;
}
