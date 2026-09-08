/**
 * @file src/platform/macos/remote_microphone_ring.h
 * @brief Bounded lock-free PCM ring used by the macOS remote microphone sink.
 */
#pragma once

// standard includes
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <new>
#include <span>

namespace platf::remote_microphone::detail {
  /**
   * @brief Single-producer, single-consumer ring of interleaved stereo float frames.
   *
   * Storage is allocated before the audio unit starts.  The producer may queue
   * only the frames that fit, so a slow output device cannot create unbounded
   * microphone latency.
   */
  class pcm_ring_t {
  public:
    static constexpr std::uint32_t capacity_frames = 2400;  ///< Maximum queued frames (50 ms at 48 kHz).
    static constexpr std::uint32_t channels = 2;  ///< Number of interleaved output channels.

    /**
     * @brief Allocate the fixed-capacity PCM storage.
     */
    pcm_ring_t():
        samples_(new (std::nothrow) float[capacity_frames * channels]) {}

    /**
     * @brief Check whether storage was allocated.
     * @return True when the ring can accept samples.
     */
    bool valid() const noexcept {
      return samples_ != nullptr;
    }

    /**
     * @brief Discard all frames currently queued in the ring.
     *
     * This is used when the output must be muted after a capture-safety state
     * change.  Only the render callback should call it; the producer remains
     * serialized through write().
     */
    void discard() noexcept {
      const auto writeIndex = writeIndex_.load(std::memory_order_acquire);
      readIndex_.store(writeIndex, std::memory_order_release);
    }

    /**
     * @brief Convert mono signed 16-bit samples and queue stereo float PCM.
     *
     * The producer owns the write position and the render callback owns the
     * read position.  Input beyond the available capacity is dropped.
     *
     * @param mono Mono signed 16-bit samples at 48 kHz.
     * @return True when every input sample was queued.
     */
    bool write(std::span<const std::int16_t> mono) noexcept {
      return write_count(mono) == mono.size();
    }

    /**
     * @brief Convert and queue as many mono samples as the ring can hold.
     *
     * This is the counted form of write() used by sink diagnostics. It has the
     * same bounded behavior and does not change the queued audio policy.
     *
     * @param mono Mono signed 16-bit samples at 48 kHz.
     * @return Number of input samples copied into the ring.
     */
    std::size_t write_count(std::span<const std::int16_t> mono) noexcept {
      if (mono.empty()) {
        return 0;
      }
      if (!samples_) {
        return 0;
      }

      const auto readIndex = readIndex_.load(std::memory_order_acquire);
      const auto writeIndex = writeIndex_.load(std::memory_order_relaxed);
      const auto usedFrames = writeIndex - readIndex;
      const auto freeFrames = usedFrames < capacity_frames ? capacity_frames - usedFrames : 0;
      const auto framesToWrite = std::min<std::uint64_t>(mono.size(), freeFrames);

      for (std::uint64_t frame = 0; frame < framesToWrite; ++frame) {
        const auto slot = ((writeIndex + frame) % capacity_frames) * channels;
        const float sample = static_cast<float>(mono[frame]) / 32768.0f;
        samples_[slot] = sample;
        samples_[slot + 1] = sample;
      }
      writeIndex_.store(writeIndex + framesToWrite, std::memory_order_release);
      return static_cast<std::size_t>(framesToWrite);
    }

    /**
     * @brief Read interleaved stereo frames into an output buffer.
     * @param destination Interleaved stereo float output.
     * @param frames Maximum frames to read.
     * @return Number of frames copied.
     */
    std::uint32_t read_interleaved(float *destination, std::uint32_t frames) noexcept {
      const auto readIndex = readIndex_.load(std::memory_order_relaxed);
      const auto writeIndex = writeIndex_.load(std::memory_order_acquire);
      const auto availableFrames = writeIndex - readIndex;
      const auto framesToRead = static_cast<std::uint32_t>(std::min<std::uint64_t>(frames, availableFrames));
      for (std::uint32_t frame = 0; frame < framesToRead; ++frame) {
        const auto slot = ((readIndex + frame) % capacity_frames) * channels;
        destination[frame * channels] = samples_[slot];
        destination[frame * channels + 1] = samples_[slot + 1];
      }
      readIndex_.store(readIndex + framesToRead, std::memory_order_release);
      return framesToRead;
    }

    /**
     * @brief Read stereo frames into two non-interleaved output buffers.
     * @param left Left output channel.
     * @param right Right output channel.
     * @param frames Maximum frames to read.
     * @return Number of frames copied.
     */
    std::uint32_t read_planar(float *left, float *right, std::uint32_t frames) noexcept {
      const auto readIndex = readIndex_.load(std::memory_order_relaxed);
      const auto writeIndex = writeIndex_.load(std::memory_order_acquire);
      const auto availableFrames = writeIndex - readIndex;
      const auto framesToRead = static_cast<std::uint32_t>(std::min<std::uint64_t>(frames, availableFrames));
      for (std::uint32_t frame = 0; frame < framesToRead; ++frame) {
        const auto slot = ((readIndex + frame) % capacity_frames) * channels;
        left[frame] = samples_[slot];
        right[frame] = samples_[slot + 1];
      }
      readIndex_.store(readIndex + framesToRead, std::memory_order_release);
      return framesToRead;
    }

  private:
    std::unique_ptr<float[]> samples_;  ///< Fixed PCM storage allocated before audio starts.
    std::atomic<std::uint64_t> readIndex_ {0};  ///< Consumer-owned monotonic read position.
    std::atomic<std::uint64_t> writeIndex_ {0};  ///< Producer-owned monotonic write position.
  };
}  // namespace platf::remote_microphone::detail
