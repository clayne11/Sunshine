/**
 * @file src/platform/macos/remote_microphone_sink.h
 * @brief Explicit-output macOS sink for remote microphone PCM.
 */
#pragma once

// standard includes
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>

namespace platf::remote_microphone {
  namespace detail {
    /**
     * @brief Lock-free counters collected by the Core Audio sink.
     *
     * The render callback updates these counters without taking a lock or
     * allocating memory. Values are cumulative for one sink instance and are
     * read only from non-real-time reporting code.
     */
    struct sink_telemetry_t {
      static_assert(std::atomic<std::uint64_t>::is_always_lock_free, "Sink telemetry counters must be lock-free.");

      std::atomic<std::uint64_t> callback_count {};  ///< Number of render callbacks observed.
      std::atomic<std::uint64_t> callback_requested_frames {};  ///< Frames requested by render callbacks.
      std::atomic<std::uint64_t> callback_read_frames {};  ///< Frames copied from the PCM ring.
      std::atomic<std::uint64_t> callback_underrun_frames {};  ///< Requested frames filled with silence because the ring was short.
      std::atomic<std::uint64_t> callback_max_gap_ticks {};  ///< Largest callback interval in mach absolute-time ticks.
      std::atomic<std::uint64_t> last_callback_host_time {};  ///< Most recent callback host timestamp used for gap tracking.
      std::atomic<std::uint64_t> format_anomalies {};  ///< Render callbacks with an unexpected or incomplete buffer layout.
      std::atomic<std::uint64_t> exclusion_muted_frames {};  ///< Frames intentionally muted while process exclusion was inactive.
      std::atomic<std::uint64_t> ring_written_samples {};  ///< Mono samples accepted by the PCM ring.
      std::atomic<std::uint64_t> ring_dropped_samples {};  ///< Mono samples rejected because the PCM ring was full or unavailable.
      std::atomic<std::uint64_t> input_rejected_samples {};  ///< Mono samples rejected before reaching the PCM ring.

      /**
       * @brief Record one render callback and update its largest observed gap.
       * @param frame_count Frames requested by this callback.
       * @param host_time Mach absolute-time timestamp for this callback.
       */
      void record_callback(std::uint32_t frame_count, std::uint64_t host_time) noexcept {
        callback_count.fetch_add(1, std::memory_order_relaxed);
        callback_requested_frames.fetch_add(frame_count, std::memory_order_relaxed);
        if (host_time == 0) {
          return;
        }

        auto previous = last_callback_host_time.load(std::memory_order_relaxed);
        while (host_time > previous && !last_callback_host_time.compare_exchange_weak(previous, host_time, std::memory_order_relaxed, std::memory_order_relaxed)) {
        }
        if (previous == 0 || host_time <= previous) {
          return;
        }

        const auto gap = host_time - previous;
        auto largest = callback_max_gap_ticks.load(std::memory_order_relaxed);
        while (gap > largest && !callback_max_gap_ticks.compare_exchange_weak(largest, gap, std::memory_order_relaxed, std::memory_order_relaxed)) {
        }
      }

      /**
       * @brief Record frames copied from the ring and frames filled with silence.
       * @param read_frames Frames copied from the ring.
       * @param underrun_frames Requested frames not available in the ring.
       */
      void record_render(std::uint32_t read_frames, std::uint32_t underrun_frames) noexcept {
        callback_read_frames.fetch_add(read_frames, std::memory_order_relaxed);
        callback_underrun_frames.fetch_add(underrun_frames, std::memory_order_relaxed);
      }

      /**
       * @brief Record one malformed render-buffer layout.
       */
      void record_format_anomaly() noexcept {
        format_anomalies.fetch_add(1, std::memory_order_relaxed);
      }

      /**
       * @brief Record intentionally muted render frames.
       * @param frame_count Frames muted by the process-exclusion gate.
       */
      void record_exclusion_mute(std::uint32_t frame_count) noexcept {
        exclusion_muted_frames.fetch_add(frame_count, std::memory_order_relaxed);
      }

      /**
       * @brief Record accepted and dropped mono input samples.
       * @param written_samples Samples accepted by the PCM ring.
       * @param dropped_samples Samples rejected by the PCM ring.
       */
      void record_ring_write(std::size_t written_samples, std::size_t dropped_samples) noexcept {
        ring_written_samples.fetch_add(written_samples, std::memory_order_relaxed);
        ring_dropped_samples.fetch_add(dropped_samples, std::memory_order_relaxed);
      }

      /**
       * @brief Record input samples rejected before the PCM ring.
       * @param sample_count Samples rejected before ring insertion.
       */
      void record_input_rejection(std::size_t sample_count) noexcept {
        input_rejected_samples.fetch_add(sample_count, std::memory_order_relaxed);
      }
    };
  }  // namespace detail

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

    /**
     * @brief Report accumulated sink timing and loss counters.
     * @details Implementations may rate-limit logging. Call this from a
     *          non-real-time sink-worker context, never from a render callback.
     */
    virtual void report_telemetry() {
    }
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
