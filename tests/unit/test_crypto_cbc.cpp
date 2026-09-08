/**
 * @file tests/unit/test_crypto_cbc.cpp
 * @brief AES-CBC known-answer and reusable-context regression tests.
 */
#include "../tests_common.h"
#include "src/crypto.h"

TEST(CryptoCbc, DecryptsNistAes128KnownAnswer) {
  crypto::aes_t key {0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c};
  crypto::aes_t iv {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f};
  const std::vector<std::uint8_t> encrypted {0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46, 0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d};
  const std::vector<std::uint8_t> expected {0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a};
  crypto::cipher::cbc_t cipher {key, false};
  std::vector<std::uint8_t> plaintext;
  EXPECT_EQ(cipher.decrypt({reinterpret_cast<const char *>(encrypted.data()), encrypted.size()}, plaintext, &iv), 0);
  EXPECT_EQ(plaintext, expected);
}

TEST(CryptoCbc, RejectsInvalidInputAndClearsPriorPlaintext) {
  crypto::aes_t key(16, 1);
  crypto::aes_t iv(16, 2);
  crypto::cipher::cbc_t cipher {key, true};
  std::vector<std::uint8_t> plaintext {1, 2, 3};
  EXPECT_EQ(cipher.decrypt("short", plaintext, &iv), -1);
  EXPECT_TRUE(plaintext.empty());
  EXPECT_EQ(cipher.decrypt(std::string(16, 'x'), plaintext, nullptr), -1);
  EXPECT_TRUE(plaintext.empty());
  crypto::aes_t short_iv(15);
  EXPECT_EQ(cipher.decrypt(std::string(16, 'x'), plaintext, &short_iv), -1);
}

TEST(CryptoCbc, ReusesContextAfterPaddingFailure) {
  crypto::aes_t key(16, 1);
  crypto::aes_t iv(16, 2);
  crypto::cipher::cbc_t encoder {key, true};
  crypto::cipher::cbc_t decoder {key, true};
  const std::string message = "voice";
  std::vector<std::uint8_t> encrypted(16);
  ASSERT_EQ(encoder.encrypt(message, encrypted.data(), &iv), 16);
  auto bad_iv = iv;
  // One-block CBC: flip the final plaintext padding byte from 11 to 10.
  bad_iv.back() ^= 1;
  const std::string_view ciphertext {reinterpret_cast<const char *>(encrypted.data()), encrypted.size()};
  std::vector<std::uint8_t> plaintext;
  EXPECT_EQ(decoder.decrypt(ciphertext, plaintext, &bad_iv), -1);
  EXPECT_TRUE(plaintext.empty());
  ASSERT_EQ(decoder.decrypt(ciphertext, plaintext, &iv), 0);
  EXPECT_EQ(std::string(plaintext.begin(), plaintext.end()), message);
}
