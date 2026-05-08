import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypt_app/utils/encryption.dart';
import 'package:crypt_app/utils/rsa_helper.dart';

void main() {
  group('EncryptionHelper', () {
    test('AES encrypt/decrypt cycle', () async {
      const plaintext = 'Hello, Crypt! 🎯';
      final encrypted = await EncryptionHelper.encryptMessage(plaintext);
      expect(encrypted.containsKey('text'), isTrue);
      expect(encrypted.containsKey('key'), isTrue);
      expect(encrypted.containsKey('iv'), isTrue);

      final decrypted = await EncryptionHelper.decryptMessage(
        encrypted['text']!,
        encrypted['key']!,
        encrypted['iv']!,
      );
      expect(decrypted, plaintext);
    });

    test('AES handles empty string', () async {
      await expectLater(
        EncryptionHelper.encryptMessage(''),
        throwsA(isA<EncryptionFormatException>()),
      );
    });

    test('AES handles unicode characters', () async {
      const plaintext = '🔒 Emoji test: 🎉👍🔥亚历山大';
      final encrypted = await EncryptionHelper.encryptMessage(plaintext);
      final decrypted = await EncryptionHelper.decryptMessage(
        encrypted['text']!,
        encrypted['key']!,
        encrypted['iv']!,
      );
      expect(decrypted, plaintext);
    });

    test('throws on invalid key length', () async {
      await expectLater(
        EncryptionHelper.decryptMessage('abc', 'invalid', 'MTIzNDU2Nzg5MDEyMzQ1Ng=='),
        throwsA(isA<EncryptionFormatException>()),
      );
    });

    test('throws on invalid IV length', () async {
      const key = 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY=';
      await expectLater(
        EncryptionHelper.decryptMessage('abc', key, 'short'),
        throwsA(isA<EncryptionFormatException>()),
      );
    });
  });

  group('RSAHelper', () {
    test('generates 2048-bit key pair', () async {
      final keyPair = await RSAHelper.generateKeyPair();
      expect(keyPair.publicKey.modulus!.bitLength, 2048);
      expect(keyPair.privateKey.privateExponent!, isNotNull);
    });

    test('RSA encrypt/decrypt cycle', () async {
      final pair = await RSAHelper.generateKeyPair();
      final plaintext = base64Encode(utf8.encode('Test message'));
      final encrypted = await RSAHelper.encrypt(plaintext, pair.publicKey);
      expect(encrypted, isNotEmpty);

      final decrypted = await RSAHelper.decrypt(encrypted, pair.privateKey);
      expect(decrypted, plaintext);
    });

    test('throws on oversized input', () async {
      final pair = await RSAHelper.generateKeyPair();
      final largeInput = base64Encode(List.filled(246, 0));

      expect(
        RSAHelper.encrypt(largeInput, pair.publicKey),
        throwsA(isA<Exception>()),
      );
    });

    test('throws on wrong ciphertext size', () async {
      final pair = await RSAHelper.generateKeyPair();
      final shortCiphertext = base64Encode(List.filled(100, 0));

      expect(
        RSAHelper.decrypt(shortCiphertext, pair.privateKey),
        throwsA(isA<Exception>()),
      );
    });
  });
}
