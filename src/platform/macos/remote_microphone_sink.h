/**
 * @file src/platform/macos/remote_microphone_sink.h
 * @brief Explicit-output macOS sink for remote microphone PCM.
 */
#pragma once

// standard includes
#include <cstdint>
#include <memory>
#include <span>
#include <string>

namespace platf::remote_microphone {
  /**
   * @brief Consumer-facing sink for mono 48 kHz signed 16-bit microphone PCM.
   */
  class sink_t {
  public:
    /**
     * @brief Destroy the sink and release its Core Audio output unit.
     */
    virtual ~sink_t();

    /**
     * @brief Queue microphone samples for the selected virtual output device.
     *
     * The implementation is bounded.  A false result means that the input
     * chunk was not queued because the output is unavailable, muted by the
     * capture-safety gate, or the output ring was full.
     *
     * @param mono48k Mono, signed 16-bit, 48 kHz samples.
     * @return True when the complete span was queued.
     */
    virtual bool write(std::span<const std::int16_t> mono48k) = 0;
  };

  /**
   * @brief Check whether an explicitly named device has an output stream.
   * @param uid Exact Core Audio device UID.
   * @return True when the device exists and exposes at least one output channel.
   */
  bool available(const std::string &uid);

  /**
   * @brief Create an output sink pinned to one exact Core Audio device UID.
   * @param uid Exact Core Audio device UID; no default-device fallback is used.
   * @return A started sink, or nullptr when the device cannot be opened.  A
   *         system-tap capture configuration may leave the sink muted until
   *         Sunshine's process exclusion is active.
   */
  std::unique_ptr<sink_t> make_sink(const std::string &uid);
}  // namespace platf::remote_microphone
