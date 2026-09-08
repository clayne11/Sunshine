/**
 * @file src/remote_microphone.cpp
 * @brief Encrypted VoidLink microphone reception and bounded-jitter playout.
 */

#include "remote_microphone.h"

// standard includes
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <map>
#include <mutex>
#include <thread>

// lib includes
#include <boost/asio.hpp>
#include <boost/endian/conversion.hpp>
#include <opus/opus.h>

// local includes
#include "config.h"
#include "logging.h"
#include "network.h"
#include "platform/common.h"
#include "utility.h"

#ifdef __APPLE__
  #include "platform/macos/remote_microphone_sink.h"
#endif

using namespace std::chrono_literals;
using namespace std::literals;

namespace remote_microphone {
  namespace {
    constexpr std::size_t header_size = 12;
    constexpr std::size_t max_datagram_size = 1400;
    constexpr std::uint8_t packet_type_opus = 0x61;
    constexpr std::uint32_t packet_magic = 0x12345678;
    constexpr std::size_t jitter_frames = 2;
    constexpr std::size_t max_buffered_packets = 4;
    constexpr std::int64_t max_late_packets = 4;
    constexpr std::int64_t max_forward_packets = 8;
    constexpr std::size_t max_consecutive_plc_frames = 2;

    std::mutex owner_mutex;  ///< Serializes single-owner admission and release.
    std::uint32_t owner_session_id {};  ///< Session currently permitted to receive microphone data.

    /**
     * @brief Destroy an Opus decoder.
     */
    struct opus_decoder_deleter_t {
      /**
       * @brief Release the decoder when present.
       * @param decoder Decoder allocated by libopus.
       */
      void operator()(OpusDecoder *decoder) const noexcept {
        if (decoder) {
          opus_decoder_destroy(decoder);
        }
      }
    };

    using opus_decoder_t = std::unique_ptr<OpusDecoder, opus_decoder_deleter_t>;

    /**
     * @brief Return signed wrap-aware distance between two 16-bit sequences.
     * @param newer Candidate sequence.
     * @param older Current maximum sequence.
     * @return Positive for a forward packet and negative for an older packet.
     */
    std::int32_t sequence_distance(std::uint16_t newer, std::uint16_t older) noexcept {
      const auto distance = static_cast<std::uint16_t>(newer - older);
      return distance < 0x8000u ? static_cast<std::int32_t>(distance) : static_cast<std::int32_t>(distance) - 0x10000;
    }

    /**
     * @brief Release the global receiver reservation when owned by a session.
     * @param session_id Session relinquishing microphone ownership.
     */
    void release_owner(std::uint32_t session_id) {
      std::lock_guard lock {owner_mutex};
      if (owner_session_id == session_id) {
        owner_session_id = 0;
      }
    }
  }  // namespace

  std::optional<sequence_result_t> sequence_window_t::accept(std::uint16_t sequence, bool reanchor_forward) {
    if (!maximum_sequence_) {
      maximum_sequence_ = sequence;
      maximum_extended_sequence_ = 0;
      admitted_ = {0};
      return sequence_result_t {0, false};
    }

    const auto distance = sequence_distance(sequence, *maximum_sequence_);
    auto extended = maximum_extended_sequence_ + distance;
    if (distance > max_forward_packets) {
      maximum_sequence_ = sequence;
      maximum_extended_sequence_ = 0;
      admitted_ = {0};
      return sequence_result_t {0, true};
    }
    if (extended < maximum_extended_sequence_ - max_late_packets || std::ranges::find(admitted_, extended) != admitted_.end()) {
      return std::nullopt;
    }
    if (reanchor_forward) {
      if (distance <= 0) {
        return std::nullopt;
      }
      maximum_sequence_ = sequence;
      maximum_extended_sequence_ = 0;
      admitted_ = {0};
      return sequence_result_t {0, true};
    }

    admitted_.push_back(extended);
    if (distance > 0) {
      maximum_sequence_ = sequence;
      maximum_extended_sequence_ = extended;
      std::erase_if(admitted_, [&](std::int64_t admitted) {
        return admitted < maximum_extended_sequence_ - max_late_packets;
      });
    }
    return sequence_result_t {extended, false};
  }

  std::optional<sequence_result_t> detail::admit_for_playout(
    sequence_window_t &window,
    std::uint16_t sequence,
    std::optional<std::int64_t> next_playout_sequence,
    bool packets_empty,
    bool playout_silent
  ) {
    auto result = window.accept(sequence, packets_empty && playout_silent);
    if (!result || (!result->reanchored && next_playout_sequence && result->extended_sequence < *next_playout_sequence)) {
      return std::nullopt;
    }
    return result;
  }

  std::optional<packet_t> decrypt_packet(std::span<const std::uint8_t> datagram, crypto::cipher::cbc_t &cipher, std::uint32_t key_id) {
    if (datagram.size() <= header_size || datagram.size() > max_datagram_size || datagram[0] != 0 || datagram[1] != packet_type_opus) {
      return std::nullopt;
    }

    std::uint16_t sequence_wire;
    std::uint32_t timestamp_wire;
    std::uint32_t ssrc_wire;
    std::memcpy(&sequence_wire, datagram.data() + 2, sizeof(sequence_wire));
    std::memcpy(&timestamp_wire, datagram.data() + 4, sizeof(timestamp_wire));
    std::memcpy(&ssrc_wire, datagram.data() + 8, sizeof(ssrc_wire));
    const auto sequence = boost::endian::little_to_native(sequence_wire);
    const auto timestamp = boost::endian::little_to_native(timestamp_wire);
    const auto ssrc = boost::endian::little_to_native(ssrc_wire);
    const auto ciphertext = datagram.subspan(header_size);
    if (ssrc != packet_magic || ciphertext.empty() || ciphertext.size() % 16 != 0) {
      return std::nullopt;
    }

    crypto::aes_t iv(16);
    const auto iv_prefix = boost::endian::native_to_big(static_cast<std::uint32_t>(key_id + sequence));
    std::memcpy(iv.data(), &iv_prefix, sizeof(iv_prefix));
    std::fill(iv.begin() + static_cast<std::ptrdiff_t>(sizeof(iv_prefix)), iv.end(), 0);

    std::vector<std::uint8_t> plaintext;
    const std::string_view encrypted {reinterpret_cast<const char *>(ciphertext.data()), ciphertext.size()};
    if (cipher.decrypt(encrypted, plaintext, &iv) != 0 || plaintext.empty() || opus_packet_get_nb_samples(plaintext.data(), static_cast<opus_int32>(plaintext.size()), 48000) != static_cast<int>(FRAME_SAMPLES)) {
      return std::nullopt;
    }

    return packet_t {sequence, timestamp, std::move(plaintext)};
  }

  /**
   * @brief Runtime state for one remote microphone receiver and playout worker.
   */
  struct session_t::impl_t {
    session_config_t config;  ///< Authenticated peer, cipher, and output configuration.
    boost::asio::io_context io_context;  ///< Execution context used to construct the UDP socket.
    boost::asio::ip::udp::socket socket {io_context};  ///< Nonblocking microphone datagram socket.
    crypto::cipher::cbc_t cipher;  ///< Reusable AES-CBC decryption context.
    opus_decoder_t decoder;  ///< Mono 48 kHz Opus decoder.
#ifdef __APPLE__
    std::unique_ptr<platf::remote_microphone::sink_t> sink;  ///< Selected Core Audio output device.
#endif
    std::jthread worker;  ///< Cooperative receiver and playout thread.
    sequence_window_t sequence_window;  ///< Replay and sequence-wrap admission state.
    std::map<std::int64_t, std::vector<std::uint8_t>> packets;  ///< Bounded ordered jitter queue.
    std::optional<std::int64_t> next_playout_sequence;  ///< Sequence expected at the next playout tick.
    std::optional<std::chrono::steady_clock::time_point> next_playout_time;  ///< Absolute next playout deadline.
    std::size_t consecutive_plc_frames {};  ///< Consecutive Opus loss-concealment frames generated.
    bool playout_silent {};  ///< Whether the jitter queue has drained into sustained silence.
    std::uint64_t received_packets {};  ///< UDP datagrams read from the socket.
    std::uint64_t accepted_packets {};  ///< Valid peer packets admitted to the jitter queue.
    std::uint64_t rejected_packets {};  ///< Packets rejected by peer, format, crypto, or replay checks.
    std::uint64_t sink_drops {};  ///< Decoded frames refused by the selected audio sink.

    /**
     * @brief Construct initialized receiver state.
     * @param session_config Authenticated session attributes.
     * @param session_cipher AES-CBC context for client packets.
     * @param opus_decoder Opus decoder for mono 48 kHz frames.
     */
    impl_t(session_config_t session_config, crypto::cipher::cbc_t session_cipher, opus_decoder_t opus_decoder):
        config {std::move(session_config)},
        cipher {std::move(session_cipher)},
        decoder {std::move(opus_decoder)} {
    }

    /**
     * @brief Receive, validate, decode, and play packets until stopped.
     * @param stop_token Cooperative stop request from the owning session.
     */
    void run(std::stop_token stop_token) {
      platf::set_thread_name("mic-recv");
      std::array<std::uint8_t, 2048> receive_buffer;
      boost::asio::ip::udp::endpoint source;
      std::array<std::int16_t, FRAME_SAMPLES> pcm;

      while (!stop_token.stop_requested()) {
        bool receive_failed = false;
        for (int attempt = 0; attempt < 16; ++attempt) {
          boost::system::error_code ec;
          const auto bytes = socket.receive_from(boost::asio::buffer(receive_buffer), source, 0, ec);
          if (ec == boost::asio::error::would_block || ec == boost::asio::error::try_again) {
            break;
          }
          if (ec) {
            if (ec == boost::asio::error::message_size) {
              ++rejected_packets;
              continue;
            }
            if (ec != boost::asio::error::operation_aborted || !stop_token.stop_requested()) {
              BOOST_LOG(warning) << "Remote microphone receive failed: "sv << ec.message();
            }
            receive_failed = true;
            break;
          }

          ++received_packets;
          if (net::normalize_address(source.address()) != net::normalize_address(config.client_address)) {
            ++rejected_packets;
            continue;
          }
          auto packet = decrypt_packet(std::span {receive_buffer.data(), bytes}, cipher, config.key_id);
          if (!packet) {
            ++rejected_packets;
            continue;
          }
          auto sequence = detail::admit_for_playout(sequence_window, packet->sequence, next_playout_sequence, packets.empty(), playout_silent);
          if (!sequence) {
            ++rejected_packets;
            continue;
          }
          if (sequence->reanchored) {
            packets.clear();
            next_playout_sequence.reset();
            next_playout_time.reset();
            consecutive_plc_frames = 0;
            playout_silent = false;
            (void) opus_decoder_ctl(decoder.get(), OPUS_RESET_STATE);
          }
          packets.emplace(sequence->extended_sequence, std::move(packet->opus_payload));
          if (packets.size() > max_buffered_packets) {
            packets.erase(std::prev(packets.end()));
          }
          if (!next_playout_sequence) {
            next_playout_sequence = sequence->extended_sequence;
            next_playout_time = std::chrono::steady_clock::now() + 20ms * jitter_frames;
          }
          ++accepted_packets;
        }

        const auto now = std::chrono::steady_clock::now();
        if (next_playout_time && now >= *next_playout_time) {
          const auto packet = packets.find(*next_playout_sequence);
          int decoded_samples;
          if (packet != packets.end()) {
            decoded_samples = opus_decode(decoder.get(), packet->second.data(), static_cast<opus_int32>(packet->second.size()), pcm.data(), static_cast<int>(pcm.size()), 0);
            packets.erase(packet);
            consecutive_plc_frames = 0;
            playout_silent = false;
          } else if (consecutive_plc_frames < max_consecutive_plc_frames) {
            decoded_samples = opus_decode(decoder.get(), nullptr, 0, pcm.data(), static_cast<int>(pcm.size()), 0);
            ++consecutive_plc_frames;
          } else {
            pcm.fill(0);
            decoded_samples = static_cast<int>(pcm.size());
            playout_silent = true;
          }

          if (decoded_samples == static_cast<int>(pcm.size())) {
#ifdef __APPLE__
            if (!sink->write(pcm)) {
              ++sink_drops;
            }
#endif
          } else {
            ++rejected_packets;
          }
          ++*next_playout_sequence;
          *next_playout_time += 20ms;
          if (now >= *next_playout_time) {
            const auto skipped_frames = static_cast<std::int64_t>((now - *next_playout_time) / 20ms) + 1;
            *next_playout_sequence += skipped_frames;
            *next_playout_time += 20ms * skipped_frames;
            std::erase_if(packets, [&](const auto &entry) {
              return entry.first < *next_playout_sequence;
            });
            consecutive_plc_frames = 0;
            playout_silent = true;
            (void) opus_decoder_ctl(decoder.get(), OPUS_RESET_STATE);
          }
        }

        if (receive_failed) {
          break;
        }

        std::this_thread::sleep_for(1ms);
      }

      BOOST_LOG(info) << "Remote microphone stopped: received="sv << received_packets
                      << ", accepted="sv << accepted_packets
                      << ", rejected="sv << rejected_packets
                      << ", sink_drops="sv << sink_drops;
    }
  };

  session_t::session_t(std::unique_ptr<impl_t> impl):
      impl_ {std::move(impl)} {
    impl_->worker = std::jthread {[state = impl_.get()](std::stop_token stop_token) {
      state->run(stop_token);
    }};
  }

  session_t::~session_t() {
    if (!impl_) {
      return;
    }
    const auto session_id = impl_->config.session_id;
    impl_->worker.request_stop();
    impl_->worker.join();
    impl_.reset();
    release_owner(session_id);
  }

  std::unique_ptr<session_t> start(session_config_t session_config) {
    if (session_config.session_id == 0 || session_config.sink_uid.empty() || !session_config.encryption_negotiated || session_config.key.size() != 16) {
      return nullptr;
    }

    std::lock_guard owner_lock {owner_mutex};
    if (owner_session_id != 0) {
      BOOST_LOG(warning) << "Remote microphone is already owned by another streaming session"sv;
      return nullptr;
    }

#ifndef __APPLE__
    return nullptr;
#else
    if (!platf::remote_microphone::available(session_config.sink_uid)) {
      BOOST_LOG(error) << "Configured remote microphone output device is unavailable"sv;
      return nullptr;
    }
    auto sink = platf::remote_microphone::make_sink(session_config.sink_uid);
    if (!sink) {
      BOOST_LOG(error) << "Failed to open configured remote microphone output device"sv;
      return nullptr;
    }

    int opus_error;
    opus_decoder_t decoder {opus_decoder_create(48000, 1, &opus_error)};
    if (!decoder || opus_error != OPUS_OK) {
      BOOST_LOG(error) << "Failed to create remote microphone Opus decoder: "sv << opus_strerror(opus_error);
      return nullptr;
    }

    crypto::cipher::cbc_t cipher {session_config.key, true};
    auto impl = std::make_unique<session_t::impl_t>(std::move(session_config), std::move(cipher), std::move(decoder));
    impl->sink = std::move(sink);

    const auto address_family = net::af_from_enum_string(config::sunshine.address_family);
    const auto protocol = address_family == net::IPV4 ? boost::asio::ip::udp::v4() : boost::asio::ip::udp::v6();
    boost::system::error_code ec;
    impl->socket.open(protocol, ec);
    if (!ec && protocol == boost::asio::ip::udp::v6()) {
      impl->socket.set_option(boost::asio::ip::v6_only(false), ec);
    }
    if (!ec) {
      const auto bind_address = boost::asio::ip::make_address(net::get_bind_address(address_family), ec);
      if (!ec) {
        impl->socket.bind(boost::asio::ip::udp::endpoint {bind_address, net::map_port(STREAM_PORT)}, ec);
      }
    }
    if (!ec) {
      impl->socket.non_blocking(true, ec);
    }
    if (ec) {
      BOOST_LOG(error) << "Failed to prepare remote microphone UDP socket: "sv << ec.message();
      return nullptr;
    }

    auto session_id = impl->config.session_id;
    BOOST_LOG(info) << "Encrypted remote microphone enabled on UDP port "sv << net::map_port(STREAM_PORT);
    auto session = std::unique_ptr<session_t> {new session_t {std::move(impl)}};
    owner_session_id = session_id;
    return session;
#endif
  }
}  // namespace remote_microphone
