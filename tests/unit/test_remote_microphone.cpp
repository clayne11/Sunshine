/**
 * @file tests/unit/test_remote_microphone.cpp
 * @brief Test encrypted remote microphone packet admission.
 */

// test includes
#include "../tests_common.h"

// standard includes
#include <algorithm>
#include <array>
#include <cstring>
#include <utility>
#include <vector>

// lib includes
#include <boost/endian/conversion.hpp>
#include <opus/opus.h>

// local includes
#include <src/remote_microphone.h>

namespace {
  constexpr std::uint32_t test_key_id = 0x10203040;

  /**
   * @brief Return deterministic AES-128 key material for packet tests.
   */
  crypto::aes_t make_key() {
    crypto::aes_t key(16);
    for (std::size_t index = 0; index < key.size(); ++index) {
      key[index] = static_cast<std::uint8_t>(index);
    }
    return key;
  }

  /**
   * @brief Encode one valid 20 ms mono Opus frame.
   */
  std::vector<std::uint8_t> make_opus_frame() {
    int error;
    auto encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &error);
    EXPECT_EQ(error, OPUS_OK);
    EXPECT_NE(encoder, nullptr);
    if (!encoder) {
      return {};
    }

    std::array<opus_int16, remote_microphone::FRAME_SAMPLES> samples {};
    std::vector<std::uint8_t> encoded(256);
    const auto bytes = opus_encode(encoder, samples.data(), static_cast<int>(samples.size()), encoded.data(), static_cast<opus_int32>(encoded.size()));
    opus_encoder_destroy(encoder);
    EXPECT_GT(bytes, 0);
    if (bytes <= 0) {
      return {};
    }
    encoded.resize(static_cast<std::size_t>(bytes));
    return encoded;
  }

  /**
   * @brief Build one encrypted VoidLink microphone datagram.
   * @param sequence Wire sequence number.
   * @param magic SSRC/magic value placed in the header.
   * @return Complete encrypted packet.
   */
  std::vector<std::uint8_t> make_datagram(std::uint16_t sequence, std::uint32_t magic = 0x12345678) {
    auto key = make_key();
    crypto::cipher::cbc_t cipher {key, true};
    crypto::aes_t iv(16);
    const auto iv_prefix = boost::endian::native_to_big(static_cast<std::uint32_t>(test_key_id + sequence));
    std::memcpy(iv.data(), &iv_prefix, sizeof(iv_prefix));

    auto opus = make_opus_frame();
    std::vector<std::uint8_t> encrypted(crypto::cipher::round_to_pkcs7_padded(opus.size()));
    const auto encrypted_size = cipher.encrypt(
      std::string_view {reinterpret_cast<const char *>(opus.data()), opus.size()},
      encrypted.data(),
      &iv
    );
    EXPECT_GT(encrypted_size, 0);
    encrypted.resize(static_cast<std::size_t>(std::max(encrypted_size, 0)));

    std::vector<std::uint8_t> datagram(12 + encrypted.size());
    datagram[0] = 0;
    datagram[1] = 0x61;
    const auto sequence_wire = boost::endian::native_to_little(sequence);
    const auto timestamp_wire = boost::endian::native_to_little<std::uint32_t>(1234);
    const auto magic_wire = boost::endian::native_to_little(magic);
    std::memcpy(datagram.data() + 2, &sequence_wire, sizeof(sequence_wire));
    std::memcpy(datagram.data() + 4, &timestamp_wire, sizeof(timestamp_wire));
    std::memcpy(datagram.data() + 8, &magic_wire, sizeof(magic_wire));
    std::copy(encrypted.begin(), encrypted.end(), datagram.begin() + 12);
    return datagram;
  }
}  // namespace

TEST(RemoteMicrophonePacketTests, DecryptsValidVoidLinkPacket) {
  auto key = make_key();
  crypto::cipher::cbc_t cipher {key, true};
  const auto packet = remote_microphone::decrypt_packet(make_datagram(7), cipher, test_key_id);

  ASSERT_TRUE(packet);
  EXPECT_EQ(packet->sequence, 7);
  EXPECT_EQ(packet->timestamp_ms, 1234);
  EXPECT_FALSE(packet->opus_payload.empty());
}

TEST(RemoteMicrophonePacketTests, RejectsWrongMagicAndMalformedCiphertext) {
  auto key = make_key();
  crypto::cipher::cbc_t cipher {key, true};
  EXPECT_FALSE(remote_microphone::decrypt_packet(make_datagram(7, 0xDEADBEEF), cipher, test_key_id));

  auto truncated = make_datagram(7);
  truncated.pop_back();
  EXPECT_FALSE(remote_microphone::decrypt_packet(truncated, cipher, test_key_id));
}

TEST(RemoteMicrophonePacketTests, UsesKeyIdToDerivePacketIv) {
  auto key = make_key();
  crypto::cipher::cbc_t cipher {key, true};
  const auto datagram = make_datagram(7);
  const auto expected = remote_microphone::decrypt_packet(datagram, cipher, test_key_id);
  const auto wrong_iv = remote_microphone::decrypt_packet(datagram, cipher, test_key_id + 1);

  ASSERT_TRUE(expected);
  EXPECT_TRUE(!wrong_iv || wrong_iv->opus_payload != expected->opus_payload);
}

TEST(RemoteMicrophoneSequenceTests, RejectsReplayAndStalePackets) {
  remote_microphone::sequence_window_t window;
  ASSERT_TRUE(window.accept(10));
  EXPECT_FALSE(window.accept(10));
  ASSERT_TRUE(window.accept(14));
  EXPECT_FALSE(window.accept(9));
  EXPECT_TRUE(window.accept(12));
  EXPECT_FALSE(window.accept(12));
}

TEST(RemoteMicrophoneSequenceTests, ExtendsSequenceAcrossWrap) {
  remote_microphone::sequence_window_t window;
  const auto first = window.accept(65535);
  const auto wrapped = window.accept(0);
  ASSERT_TRUE(first);
  ASSERT_TRUE(wrapped);
  EXPECT_EQ(first->extended_sequence, 0);
  EXPECT_EQ(wrapped->extended_sequence, 1);
  EXPECT_FALSE(wrapped->reanchored);
}

TEST(RemoteMicrophoneSequenceTests, ReanchorsLargeForwardDiscontinuity) {
  remote_microphone::sequence_window_t window;
  ASSERT_TRUE(window.accept(100));
  const auto restarted = window.accept(120);
  ASSERT_TRUE(restarted);
  EXPECT_EQ(restarted->extended_sequence, 0);
  EXPECT_TRUE(restarted->reanchored);
}

TEST(RemoteMicrophoneSequenceTests, ReanchorsFreshForwardPacketAfterSilence) {
  remote_microphone::sequence_window_t window;
  ASSERT_TRUE(window.accept(100));

  std::int64_t next_playout_sequence = 100;
  for (int frame = 0; frame < 1000; ++frame) {
    ++next_playout_sequence;
  }

  const auto resumed = remote_microphone::detail::admit_for_playout(window, 101, next_playout_sequence, true, true);
  ASSERT_TRUE(resumed);
  EXPECT_EQ(resumed->extended_sequence, 0);
  EXPECT_TRUE(resumed->reanchored);

  // The worker resets its playout origin to the resumed packet's timeline.
  next_playout_sequence = resumed->extended_sequence;
  EXPECT_FALSE(remote_microphone::detail::admit_for_playout(window, 101, next_playout_sequence, false, false));

  const auto next = remote_microphone::detail::admit_for_playout(window, 102, next_playout_sequence, false, false);
  ASSERT_TRUE(next);
  EXPECT_EQ(next->extended_sequence, 1);
  EXPECT_FALSE(next->reanchored);
}

TEST(RemoteMicrophoneSequenceTests, DoesNotReanchorLatePacketAfterSilence) {
  remote_microphone::sequence_window_t window;
  ASSERT_TRUE(window.accept(100));
  ASSERT_TRUE(window.accept(101));

  EXPECT_FALSE(window.accept(100, true));
}

TEST(RemoteMicrophoneSessionTests, RefusesDisabledOrUnencryptedSessionBeforeOpeningDevice) {
  remote_microphone::session_config_t config {
    .session_id = 1,
    .client_address = boost::asio::ip::make_address("127.0.0.1"),
    .key = make_key(),
    .key_id = test_key_id,
    .sink_uid = "unused-test-device",
    .encryption_negotiated = false,
  };
  EXPECT_EQ(remote_microphone::start(config), nullptr);

  config.encryption_negotiated = true;
  config.sink_uid.clear();
  EXPECT_EQ(remote_microphone::start(std::move(config)), nullptr);
}
