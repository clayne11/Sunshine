/**
 * @file src/remote_microphone.h
 * @brief Encrypted VoidLink microphone reception and playout.
 */
#pragma once

// standard includes
#include <cstddef>
#include <cstdint>
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

    std::unique_ptr<impl_t> impl_;  ///< Receiver, decoder, socket, and sink state.

    friend std::unique_ptr<session_t> start(session_config_t config);
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
