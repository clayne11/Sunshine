/**
 * @file src/remote_microphone.h
 * @brief Encrypted VoidLink microphone reception and playout.
 */
#pragma once

// standard includes
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

// lib includes
#include <boost/asio/ip/address.hpp>

// local includes
#include "crypto.h"

namespace remote_microphone {
  class session_t;
  struct session_config_t;

  constexpr auto STREAM_PORT = 12;  ///< GameStream base-port offset used for microphone UDP packets.
  constexpr std::uint32_t ENCRYPTION_FLAG = 0x08;  ///< VoidLink/Sunshine microphone encryption feature bit.
  constexpr std::size_t FRAME_SAMPLES = 960;  ///< Samples in one 20 ms mono 48 kHz microphone frame.

  /**
   * @brief Decrypted microphone packet fields.
   */
  struct packet_t {
    std::uint16_t sequence;  ///< Little-endian wire sequence converted to host order.
    std::uint32_t timestamp_ms;  ///< Client monotonic timestamp in milliseconds.
    std::vector<std::uint8_t> opus_payload;  ///< One validated 20 ms Opus frame.
  };

  /**
   * @brief Result of admitting a packet into the bounded sequence window.
   */
  struct sequence_result_t {
    std::int64_t extended_sequence;  ///< Wrap-aware sequence used to order jitter-buffer entries.
    bool reanchored;  ///< True when a large forward discontinuity started a new timeline.
  };

  /**
   * @brief Reject replayed and stale packets while extending 16-bit sequence numbers.
   */
  class sequence_window_t {
  public:
    /**
     * @brief Admit a wire sequence number into the current bounded window.
     * @param sequence 16-bit little-endian sequence after host-order conversion.
     * @param reanchor_forward Start a new timeline when a nonduplicate packet advances the window.
     * @return Extended sequence information, or no value for a replay or stale packet.
     */
    std::optional<sequence_result_t> accept(std::uint16_t sequence, bool reanchor_forward = false);

  private:
    std::optional<std::uint16_t> maximum_sequence_;  ///< Newest admitted wire sequence.
    std::int64_t maximum_extended_sequence_ {0};  ///< Extended value paired with the newest sequence.
    std::vector<std::int64_t> admitted_;  ///< Recently admitted values retained for replay detection.
  };

  namespace detail {
    using pcm_frame_t = std::array<std::int16_t, FRAME_SAMPLES>;  ///< One decoded microphone frame.
    using jitter_packet_queue_t = std::map<std::int64_t, std::vector<std::uint8_t>>;  ///< Ordered decrypted Opus-payload playout queue.

    /**
     * @brief Result of enforcing the jitter queue's capacity.
     */
    struct jitter_trim_result_t {
      bool overflow {};  ///< Whether at least one packet exceeded the queue capacity.
      std::uint64_t skipped_frames {};  ///< Playout positions skipped while rebasing to retained audio.
    };

    /**
     * @brief Enforce a bounded jitter queue after packet insertion.
     *
     * @param packets Ordered admitted packets.
     * @param max_packets Maximum retained packet count.
     * @param next_playout_sequence Sequence expected by the playout clock, when initialized.
     * @return Capacity and playout-rebase details.
     */
    jitter_trim_result_t trim_jitter_queue(
      jitter_packet_queue_t &packets,
      std::size_t max_packets,
      std::optional<std::int64_t> &next_playout_sequence
    );

    /**
     * @brief State of the quarantined Core Audio sink initializer.
     */
    enum class sink_state_e {
      pending,  ///< Device initialization has not completed.
      ready,  ///< The sink worker can accept decoded audio.
      failed,  ///< Device initialization failed.
      canceled,  ///< The streaming session ended before or after initialization.
    };

    /**
     * @brief Bounded mailbox shared with the quarantined sink worker.
     */
    class sink_mailbox_t {
    public:
      /**
       * @brief Construct an empty pending mailbox.
       */
      sink_mailbox_t();

      /**
       * @brief Release mailbox synchronization state.
       */
      ~sink_mailbox_t();

      sink_mailbox_t(const sink_mailbox_t &) = delete;
      sink_mailbox_t &operator=(const sink_mailbox_t &) = delete;

      /**
       * @brief Publish a successfully initialized sink unless teardown won the race.
       * @return True when decoded frames may now be accepted.
       */
      bool activate();

      /**
       * @brief Publish initialization failure unless the session was canceled.
       * @return True when the mailbox transitioned to failed.
       */
      bool fail();

      /**
       * @brief Cancel pending or active delivery and discard queued audio.
       */
      void cancel();

      /**
       * @brief Queue the newest decoded frame without adding a playout delay.
       * @param samples One complete mono 48 kHz frame.
       * @return True when the ready sink accepted the frame without replacing queued audio.
       */
      bool write(std::span<const std::int16_t> samples);

      /**
       * @brief Wait for and synchronously deliver the next frame.
       *
       * The bounded consumer runs behind the cancellation barrier and must not
       * call back into this mailbox.
       *
       * @param consumer Bounded sink write invoked with one complete frame.
       * @return False after cancellation or failure; true after one delivery.
       */
      bool consume_frame(const std::function<void(std::span<const std::int16_t>)> &consumer);

      /**
       * @brief Read the current initializer state.
       * @return Current sink state.
       */
      sink_state_e state() const;

    private:
      struct impl_t;
      std::unique_ptr<impl_t> impl_;  ///< Mutex, notification, state, and bounded frame slot.
    };

    /**
     * @brief Permit at most one quarantined initializer task at a time.
     *
     * Detached tasks retain only the gate's private state. A permanently blocked
     * platform call therefore consumes one contained worker and makes later
     * submissions fail quickly instead of accumulating threads.
     */
    class initializer_gate_t {
    public:
      /**
       * @brief Construct an idle initializer gate.
       */
      initializer_gate_t();

      /**
       * @brief Release this handle while detached tasks retain private state.
       */
      ~initializer_gate_t();

      initializer_gate_t(const initializer_gate_t &) = delete;
      initializer_gate_t &operator=(const initializer_gate_t &) = delete;

      /**
       * @brief Start one detached quarantined task when the gate is idle.
       * @param task Platform initializer and sink lifetime task.
       * @return True when the task was started.
       */
      bool try_run(std::function<void()> task);

      /**
       * @brief Check whether a quarantined task still owns the gate.
       * @return True while initialization, playback, or disposal is running.
       */
      bool busy() const noexcept;

    private:
      struct state_t;
      std::shared_ptr<state_t> state_;  ///< Process-safe state retained by a detached task.
    };

    using sink_worker_t = std::function<void(std::shared_ptr<sink_mailbox_t>)>;  ///< Isolated sink lifetime task.

    /**
     * @brief Start a receiver with an injectable sink worker and UDP port.
     *
     * This seam exercises complete session teardown without opening Core Audio
     * or a fixed public UDP port.
     *
     * @param config Authenticated receiver configuration.
     * @param gate Single-worker quarantine gate.
     * @param sink_worker Injectable sink initialization and lifetime task.
     * @param port UDP port, or zero for an ephemeral test port.
     * @return Owning session handle, or nullptr when invalid, busy, or unavailable.
     */
    std::unique_ptr<session_t> start_for_testing(session_config_t config, initializer_gate_t &gate, sink_worker_t sink_worker, std::uint16_t port);

    /**
     * @brief Admit one packet using the receiver's current playout state.
     *
     * A forward packet may establish a new timeline after the jitter queue has
     * drained into silence.  Otherwise a packet older than the next playout
     * sequence is rejected as stale.
     *
     * @param window Sequence replay and wrap window.
     * @param sequence Wire sequence number after host-order conversion.
     * @param next_playout_sequence Sequence expected by the playout clock, when initialized.
     * @param packets_empty Whether the jitter queue is empty before admission.
     * @param playout_silent Whether the receiver has entered sustained silence.
     * @return Extended sequence information, or no value when the packet is stale or replayed.
     */
    std::optional<sequence_result_t> admit_for_playout(
      sequence_window_t &window,
      std::uint16_t sequence,
      std::optional<std::int64_t> next_playout_sequence,
      bool packets_empty,
      bool playout_silent
    );
  }  // namespace detail

  /**
   * @brief Session attributes required to authorize one microphone receiver.
   */
  struct session_config_t {
    std::uint32_t session_id;  ///< Authenticated RTSP launch identifier.
    boost::asio::ip::address client_address;  ///< Only accepted UDP source address.
    crypto::aes_t key;  ///< Session AES-128 key negotiated by the paired client.
    std::uint32_t key_id;  ///< Big-endian launch IV prefix converted to host order.
    std::string sink_uid;  ///< Exact Core Audio output device UID.
    bool encryption_negotiated;  ///< Whether the client accepted microphone encryption.
  };

  /**
   * @brief Own one encrypted microphone receive and playout session.
   */
  class session_t {
  public:
    /**
     * @brief Stop reception, drain callbacks, and release the output sink.
     */
    ~session_t();

    /**
     * @brief Microphone sessions cannot share a socket, decoder, or device owner.
     */
    session_t(const session_t &) = delete;
    /**
     * @brief Microphone sessions cannot be reassigned while their worker is active.
     * @return This session is never reassigned.
     */
    session_t &operator=(const session_t &) = delete;

  private:
    struct impl_t;

    /**
     * @brief Adopt a fully initialized receiver implementation.
     * @param impl Receiver state whose worker has not yet started.
     */
    explicit session_t(std::unique_ptr<impl_t> impl);

    std::unique_ptr<impl_t> impl_;  ///< Receiver, decoder, socket, and sink mailbox state.

    friend std::unique_ptr<session_t> start(session_config_t config);
    friend std::unique_ptr<session_t> detail::start_for_testing(session_config_t config, detail::initializer_gate_t &gate, detail::sink_worker_t sink_worker, std::uint16_t port);
  };

  /**
   * @brief Decrypt and validate one VoidLink microphone datagram.
   * @param datagram Complete UDP datagram including the 12-byte wire header.
   * @param cipher AES-CBC context initialized with the authenticated session key.
   * @param key_id Host-order key identifier derived from the launch IV.
   * @return Parsed packet, or no value for malformed, undecryptable, or non-Opus data.
   */
  std::optional<packet_t> decrypt_packet(std::span<const std::uint8_t> datagram, crypto::cipher::cbc_t &cipher, std::uint32_t key_id);

  /**
   * @brief Start microphone reception for one authenticated RTSP session.
   * @details A process permits one microphone owner at a time and never falls back
   *          to a default audio device when the configured UID is unavailable.
   * @param config Authenticated client, key, encryption, and sink configuration.
   * @return Owning session handle, or nullptr when disabled, unavailable, or busy.
   */
  std::unique_ptr<session_t> start(session_config_t config);
}  // namespace remote_microphone
