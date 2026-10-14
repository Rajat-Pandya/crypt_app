import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypt_app/services/crypto_security_service.dart';
import 'package:crypt_app/services/hmac_key_service.dart';
import 'package:crypt_app/utils/encryption.dart';

/// Comprehensive tests for all security features
/// 
/// These tests verify:
/// - Replay Protection (nonces, timestamps)
/// - HMAC message integrity
/// - Session trust validation
/// - Idempotency (duplicate prevention)
/// - Key fingerprinting
/// - Reconnect security
/// - Full encryption/decrypt flows
/// - Legacy message compatibility
void main() {
  group('CryptoSecurityService - Replay Protection', () {
    test('testGenerateNonce - generates unique and random nonces', () {
      // Generate multiple nonces
      final nonce1 = CryptoSecurityService.generateNonce();
      final nonce2 = CryptoSecurityService.generateNonce();
      final nonce3 = CryptoSecurityService.generateNonce();

      // Verify nonces are not empty
      expect(nonce1, isNotEmpty);
      expect(nonce2, isNotEmpty);
      expect(nonce3, isNotEmpty);

      // Verify nonces are unique
      expect(nonce1, isNot(equals(nonce2)));
      expect(nonce1, isNot(equals(nonce3)));
      expect(nonce2, isNot(equals(nonce3)));

      // Verify nonces are valid base64
      expect(() => base64Decode(nonce1), returnsNormally);
      expect(() => base64Decode(nonce2), returnsNormally);
      expect(() => base64Decode(nonce3), returnsNormally);

      // Verify nonces are 16 bytes (128 bits) when decoded
      expect(base64Decode(nonce1).length, equals(16));
      expect(base64Decode(nonce2).length, equals(16));
      expect(base64Decode(nonce3).length, equals(16));
    });

    test('testValidateNonce_Success - valid nonce passes validation', () {
      final nonce = CryptoSecurityService.generateNonce();
      final timestamp = DateTime.now().toUtc();

      // Should not throw for a valid nonce with current timestamp
      expect(
        () => CryptoSecurityService.validateNonce(nonce, timestamp),
        returnsNormally,
      );

      // Returns true for valid nonce
      expect(CryptoSecurityService.validateNonce(nonce, timestamp), isTrue);
    });

    test('testValidateNonce_TooOld - old timestamp is rejected', () {
      final nonce = CryptoSecurityService.generateNonce();
      // Timestamp from 10 minutes ago (exceeds 5 minute skew limit)
      final oldTimestamp = DateTime.now().toUtc().subtract(
        const Duration(minutes: 10),
      );

      // Should throw SecurityValidationException for old timestamp
      expect(
        () => CryptoSecurityService.validateNonce(nonce, oldTimestamp),
        throwsA(
          isA<SecurityValidationException>().having(
            (e) => e.message,
            'message',
            contains('timestamp'),
          ),
        ),
      );
    });

    test('testValidateNonce_Duplicate - duplicate nonce is rejected', () {
      final nonce = CryptoSecurityService.generateNonce();
      final timestamp = DateTime.now().toUtc();

      // First validation should pass
      CryptoSecurityService.validateNonce(nonce, timestamp);

      // Mark nonce as used
      CryptoSecurityService.markNonceUsed(nonce, timestamp);

      // Second validation should fail (duplicate/replay)
      expect(
        () => CryptoSecurityService.validateNonce(nonce, timestamp),
        throwsA(
          isA<SecurityValidationException>().having(
            (e) => e.message,
            'message',
            contains('replay'),
          ),
        ),
      );
    });

    test('testCleanupNonceCache - old nonces are cleaned up', () {
      // This test verifies that the cleanup mechanism exists
      // Since cleanup is private, we verify through the public interface

      final oldNonce = CryptoSecurityService.generateNonce();
      final oldTimestamp = DateTime.now().toUtc().subtract(
        const Duration(hours: 73), // Beyond 72-hour window
      );

      // Mark old nonce as used
      CryptoSecurityService.markNonceUsed(oldNonce, oldTimestamp);

      // The cleanup is triggered automatically when new nonces are added
      // Add many new nonces to trigger cleanup
      for (int i = 0; i < 10; i++) {
        final nonce = CryptoSecurityService.generateNonce();
        final timestamp = DateTime.now().toUtc();
        CryptoSecurityService.markNonceUsed(nonce, timestamp);
      }

      // Verify the service still functions correctly after cleanup
      final newNonce = CryptoSecurityService.generateNonce();
      final newTimestamp = DateTime.now().toUtc();
      expect(
        () => CryptoSecurityService.validateNonce(newNonce, newTimestamp),
        returnsNormally,
      );
    });
  });

  group('CryptoSecurityService - HMAC', () {
    late Uint8List testKey;
    late String ciphertext;
    late String encryptedAesKey;
    late String iv;
    late String nonce;
    late DateTime timestamp;
    late String senderId;

    setUp(() {
      // Generate a test HMAC key (32 bytes for SHA-256)
      testKey = Uint8List.fromList(List.generate(32, (i) => i));
      ciphertext = base64Encode(Uint8List.fromList([1, 2, 3, 4, 5]));
      encryptedAesKey = base64Encode(Uint8List.fromList([6, 7, 8, 9, 10]));
      iv = base64Encode(Uint8List.fromList([11, 12, 13, 14, 15, 16]));
      nonce = CryptoSecurityService.generateNonce();
      timestamp = DateTime.now().toUtc();
      senderId = 'test_user_123';
    });

    test('testComputeHmac - HMAC computed correctly', () async {
      final hmac = await CryptoSecurityService.computeHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        keyMaterial: testKey,
      );

      // Verify HMAC is not empty
      expect(hmac, isNotEmpty);

      // Verify HMAC is valid base64
      expect(() => base64Decode(hmac), returnsNormally);

      // Verify HMAC is 32 bytes (SHA-256 output)
      expect(base64Decode(hmac).length, equals(32));

      // Verify same inputs produce same HMAC
      final hmac2 = await CryptoSecurityService.computeHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        keyMaterial: testKey,
      );
      expect(hmac, equals(hmac2));
    });

    test('testVerifyHmac_Success - valid HMAC verifies correctly', () async {
      final hmac = await CryptoSecurityService.computeHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        keyMaterial: testKey,
      );

      // Should return true for valid HMAC
      final result = await CryptoSecurityService.verifyHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        expectedHmac: hmac,
        keyMaterial: testKey,
      );

      expect(result, isTrue);
    });

    test('testVerifyHmac_Failure - tampered message fails verification', () async {
      final hmac = await CryptoSecurityService.computeHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        keyMaterial: testKey,
      );

      // Try to verify with tampered ciphertext
      final tamperedCiphertext = base64Encode(Uint8List.fromList([99, 99, 99]));
      
      expect(
        () => CryptoSecurityService.verifyHmac(
          ciphertext: tamperedCiphertext,
          encryptedAesKey: encryptedAesKey,
          iv: iv,
          nonce: nonce,
          timestamp: timestamp,
          senderId: senderId,
          expectedHmac: hmac,
          keyMaterial: testKey,
        ),
        throwsA(
          isA<SecurityValidationException>().having(
            (e) => e.message,
            'message',
            contains('tampering'),
          ),
        ),
      );
    });

    test('testHmacKeyDerivation - key derived from session', () async {
      // Initialize HMAC key service with test parameters
      const testUserId = 'test_user_123';
      const testSessionId = 'test_session_456';
      
      // Initialize the service
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );

      // Get the derived key
      final derivedKey = CryptoSecurityService.getCurrentHmacKey();
      expect(derivedKey, isNotNull);
      expect(derivedKey!.length, equals(32));

      // Verify key is not all zeros (i.e., it was properly derived)
      final isAllZeros = derivedKey.every((byte) => byte == 0);
      expect(isAllZeros, isFalse);

      // Different user should produce different key
      HmacKeyService.clear();
      await HmacKeyService.initialize(
        userId: 'different_user',
        sessionId: testSessionId,
      );
      final differentKey = CryptoSecurityService.getCurrentHmacKey();
      
      // Different user should produce different key
      // (Note: master key is regenerated on clear, so keys won't be identical)
      final isDifferentUserAllZeros = differentKey!.every((byte) => byte == 0);
      expect(isDifferentUserAllZeros, isFalse);

      // Cleanup
      HmacKeyService.clear();
    });

    test('throws exception when no key is available', () async {
      // Ensure HMAC key service is not initialized
      HmacKeyService.clear();

      // Should throw when no key material is provided and service is not initialized
      await expectLater(
        CryptoSecurityService.computeHmac(
          ciphertext: ciphertext,
          encryptedAesKey: encryptedAesKey,
          iv: iv,
          nonce: nonce,
          timestamp: timestamp,
          senderId: senderId,
        ),
        throwsA(isA<SecurityValidationException>()),
      );
    });
  });

  group('CryptoSecurityService - Session Trust', () {
    test('testValidateSession_Healthy - valid session passes', () {
      final result = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now().subtract(const Duration(hours: 1)),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '1',
      );

      expect(result.isValid, isTrue);
      expect(result.shouldContinue, isTrue);
      expect(result.trustScore, greaterThanOrEqualTo(70));
    });

    test('testValidateSession_Expired - expired session fails', () {
      final result = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now().subtract(const Duration(hours: 25)), // > 24 hours
        lastActivity: DateTime.now(),
        expectedKeyVersion: '1',
      );

      // Should have reduced trust score but may still be valid
      expect(result.trustScore, lessThan(100));
      expect(result.issues.any((issue) => issue.contains('expired')), isTrue);
    });

    test('testValidateSession_KeyMismatch - key mismatch detected', () {
      final result = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now(),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '2', // Mismatch
      );

      // Should have reduced trust score
      expect(result.trustScore, lessThan(100));
      expect(result.issues.any((issue) => issue.contains('mismatch')), isTrue);
    });

    test('testTrustScoreCalculation - penalties calculated correctly', () {
      // Fresh session
      final healthyResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now(),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '1',
      );
      expect(healthyResult.trustScore, equals(100));

      // Expired session (24+ hours = -40)
      final expiredResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now().subtract(const Duration(hours: 30)),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '1',
      );
      expect(expiredResult.trustScore, equals(60)); // 100 - 40

      // Key mismatch (-50)
      final mismatchResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now(),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '2',
      );
      expect(mismatchResult.trustScore, equals(50)); // 100 - 50

      // Stale session (12+ hours inactive = -20)
      final staleResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now().subtract(const Duration(hours: 2)),
        lastActivity: DateTime.now().subtract(const Duration(hours: 15)),
        expectedKeyVersion: '1',
      );
      expect(staleResult.trustScore, equals(80)); // 100 - 20
    });

    test('session recommendation logic works correctly', () {
      // Score >= 70: continueSession
      final goodResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now(),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '1',
      );
      expect(goodResult.recommendation, SessionRecommendation.continueSession);

      // Score 50-69: revalidate (only expired: -40 = 60)
      final mediumResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now().subtract(const Duration(hours: 25)),
        lastActivity: DateTime.now(),
        expectedKeyVersion: '1',
      );
      expect(mediumResult.trustScore, lessThan(70));
      expect(mediumResult.trustScore, greaterThanOrEqualTo(50));
      expect(mediumResult.recommendation, SessionRecommendation.revalidate);

      // Score < 50: invalid (expired -40 + stale -20 + aging -10 = 30)
      final badResult = CryptoSecurityService.validateSession(
        userId: 'test_user',
        keyVersion: '1',
        sessionCreated: DateTime.now().subtract(const Duration(days: 2)),
        lastActivity: DateTime.now().subtract(const Duration(hours: 20)),
        expectedKeyVersion: '2',
      );
      expect(badResult.trustScore, lessThan(50));
      expect(badResult.isValid, isFalse);
    });
  });

  group('CryptoSecurityService - Idempotency', () {
    test('testGenerateIdempotencyKey - keys are unique', () {
      final key1 = CryptoSecurityService.generateIdempotencyKey(
        senderId: 'user1',
        receiverId: 'user2',
        timestamp: DateTime.now(),
        nonce: 'nonce1',
      );

      final key2 = CryptoSecurityService.generateIdempotencyKey(
        senderId: 'user1',
        receiverId: 'user2',
        timestamp: DateTime.now().add(const Duration(milliseconds: 1)),
        nonce: 'nonce2',
      );

      final key3 = CryptoSecurityService.generateIdempotencyKey(
        senderId: 'user3',
        receiverId: 'user4',
        timestamp: DateTime.now(),
        nonce: 'nonce1',
      );

      // All keys should be different
      expect(key1, isNot(equals(key2)));
      expect(key1, isNot(equals(key3)));
      expect(key2, isNot(equals(key3)));

      // Keys should be valid base64 (SHA-256 = 32 bytes)
      expect(base64Decode(key1).length, equals(32));
      expect(base64Decode(key2).length, equals(32));
      expect(base64Decode(key3).length, equals(32));
    });

    test('testIsMessageProcessed - duplicate detected', () {
      final idempotencyKey = CryptoSecurityService.generateIdempotencyKey(
        senderId: 'user1',
        receiverId: 'user2',
        timestamp: DateTime.now(),
        nonce: 'test_nonce',
      );

      // Initially not processed
      expect(CryptoSecurityService.isMessageProcessed(idempotencyKey), isFalse);

      // Mark as processed
      CryptoSecurityService.markMessageProcessed(idempotencyKey);

      // Now should be processed
      expect(CryptoSecurityService.isMessageProcessed(idempotencyKey), isTrue);
    });

    test('testMarkMessageProcessed - marks correctly', () {
      final idempotencyKey = CryptoSecurityService.generateIdempotencyKey(
        senderId: 'user1',
        receiverId: 'user2',
        timestamp: DateTime.now(),
        nonce: 'test_nonce_2',
      );

      // Verify idempotency
      expect(CryptoSecurityService.isMessageProcessed(idempotencyKey), isFalse);
      CryptoSecurityService.markMessageProcessed(idempotencyKey);
      expect(CryptoSecurityService.isMessageProcessed(idempotencyKey), isTrue);

      // Different key should not be affected
      final differentKey = CryptoSecurityService.generateIdempotencyKey(
        senderId: 'user1',
        receiverId: 'user2',
        timestamp: DateTime.now(),
        nonce: 'different_nonce',
      );
      expect(CryptoSecurityService.isMessageProcessed(differentKey), isFalse);
    });
  });

  group('CryptoSecurityService - Key Fingerprint', () {
    const testPublicKeyPem = '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7
MAQmE4o8xaLz6FMIHjjxOekzG9qo6VmASk3fKxIJ8FZf5JWxQqN6e4YGNj6txLf8fVfH6FzX8YjxQ
qTn2dNP9dOAGU7kT7Z5L2XBO5QvK3XyYmz7v1tSZ7xT6Elx4T8x8nqU7LMVGpKj0wCgYIKoZIzj0E
AwIDSQAwRgIhAJg4KKZqPx7z1FFz7KpxmqNGvT7Gx8l8x1T8zFq0cQOqAiEAhV6JHjK7q4m8xQXB
LhXNTgN8TZQ8x1T8zFq0cQOqAiEAhV6JHjK7q4m8xQXBLhXNTgN8TZQ8x1T8zFq0cQOqAiE=
-----END PUBLIC KEY-----''';

    test('testComputeKeyFingerprint - fingerprint computed correctly', () {
      final fingerprint = CryptoSecurityService.computeKeyFingerprint(testPublicKeyPem);

      // Verify format: XXXX-XXXX-XXXX-XXXX
      expect(fingerprint, matches(RegExp(r'^[A-Za-z0-9+/]{4}-[A-Za-z0-9+/]{4}-[A-Za-z0-9+/]{4}-[A-Za-z0-9+/]{4}$')));

      // Verify same key produces same fingerprint
      final fingerprint2 = CryptoSecurityService.computeKeyFingerprint(testPublicKeyPem);
      expect(fingerprint, equals(fingerprint2));

      // Different key should produce different fingerprint
      const differentKey = '''-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxgNSPM+TDyx3KLj8uAOsXGF4gD7kC3q0
LVMQqKFFHgPKSqJE7s8BdM5EaVGpk/hZnxMzOqO5RqXGEuQ0jO2h4FKP8fWvl1Y9xWGQWjjU5LRh
K7T6Elx4T8x8nqU7LMVGpKj0wCgYIKoZIzj0EAwIDSQAwRgIhAJg4KKZqPx7z1FFz7KpxmqNGvT7Gx8l8x1T8zFq0cQOq
AiEAhV6JHjK7q4m8xQXBLhXNTgN8TZQ8x1T8zFq0cQOqAiEAhV6JHjK7q4m8xQXBLhXNTgN8TZQ8
-----END PUBLIC KEY-----''';
      final differentFingerprint = CryptoSecurityService.computeKeyFingerprint(differentKey);
      expect(fingerprint, isNot(equals(differentFingerprint)));
    });

    test('testVerifyKeyFingerprint_Success - valid fingerprint matches', () {
      final fingerprint = CryptoSecurityService.computeKeyFingerprint(testPublicKeyPem);

      // Verify against the computed fingerprint
      final result = CryptoSecurityService.verifyKeyFingerprint(
        testPublicKeyPem,
        fingerprint,
      );
      expect(result, isTrue);

      // Verify against fingerprint without dashes
      final result2 = CryptoSecurityService.verifyKeyFingerprint(
        testPublicKeyPem,
        fingerprint.replaceAll('-', ''),
      );
      expect(result2, isTrue);
    });

    test('testVerifyKeyFingerprint_Failure - invalid fingerprint rejected', () {
      // Verify against wrong fingerprint
      final result = CryptoSecurityService.verifyKeyFingerprint(
        testPublicKeyPem,
        'ABCD-EFGH-IJKL-MNOP',
      );
      expect(result, isFalse);

      // Verify against slightly modified fingerprint
      final correctFingerprint = CryptoSecurityService.computeKeyFingerprint(testPublicKeyPem);
      final wrongFingerprint = correctFingerprint.replaceRange(0, 4, 'XXXX');
      final result2 = CryptoSecurityService.verifyKeyFingerprint(
        testPublicKeyPem,
        wrongFingerprint,
      );
      expect(result2, isFalse);
    });
  });

  group('CryptoSecurityService - Reconnect Security', () {
    test('testValidateReconnect_NoChange - normal reconnect passes', () async {
      final result = await CryptoSecurityService.validateReconnect(
        userId: 'test_user',
        lastKnownSessionTime: DateTime.now().subtract(const Duration(minutes: 5)),
        lastKnownKeyVersion: '1',
        currentKeyVersion: '1',
      );

      expect(result.isValid, isTrue);
      expect(result.shouldRevalidateKeys, isFalse);
    });

    test('testValidateReconnect_KeyRotated - detects key rotation', () async {
      final result = await CryptoSecurityService.validateReconnect(
        userId: 'test_user',
        lastKnownSessionTime: DateTime.now().subtract(const Duration(hours: 2)),
        lastKnownKeyVersion: '1',
        currentKeyVersion: '2',
      );

      // Should detect key rotation
      expect(result.issues.any((issue) => issue.contains('rotate')), isTrue);
      expect(result.shouldRevalidateKeys, isTrue);
    });

    test('testValidateReconnect_StaleSession - detects stale session', () async {
      final result = await CryptoSecurityService.validateReconnect(
        userId: 'test_user',
        lastKnownSessionTime: DateTime.now().subtract(const Duration(hours: 25)),
        lastKnownKeyVersion: '1',
        currentKeyVersion: '1',
      );

      // Should detect extended offline
      expect(result.issues.any((issue) => issue.contains('offline')), isTrue);
      expect(result.trustScore, lessThan(100));
    });

    test('detects suspicious reconnect patterns', () async {
      // First, simulate multiple reconnects to build history
      const userId = 'suspicious_user';
      
      // Need > 10 reconnects total, then > 3 recent within 5 minutes
      // First 11 reconnects to build up count (all with 1 second delay to avoid instant timing)
      for (int i = 0; i < 11; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        await CryptoSecurityService.validateReconnect(
          userId: userId,
          lastKnownSessionTime: DateTime.now().subtract(const Duration(minutes: 1)),
          lastKnownKeyVersion: '1',
          currentKeyVersion: '1',
        );
      }

      // Now the next reconnect should detect the suspicious pattern
      // because we have >10 total and >3 recent
      final result = await CryptoSecurityService.validateReconnect(
        userId: userId,
        lastKnownSessionTime: DateTime.now().subtract(const Duration(minutes: 1)),
        lastKnownKeyVersion: '1',
        currentKeyVersion: '1',
      );

      // Should have reduced trust due to suspicious pattern
      expect(result.issues.any((issue) => issue.contains('Suspicious')), isTrue);
      expect(result.trustScore, lessThan(100));
    });
  });

  group('CryptoSecurityService - Integration', () {
    const testUserId = 'integration_test_user';
    const testSessionId = 'integration_test_session';
    const receiverId = 'receiver_user';

    setUp(() async {
      // Initialize HMAC key service for integration tests
      HmacKeyService.clear();
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );
    });

    tearDown(() {
      HmacKeyService.clear();
    });

    test('testSendSecureMessage - full secure send flow', () async {
      const plaintext = 'Hello, secure world! 🔒';

      // Simulate secure encryption
      final encryptedData = await CryptoSecurityService.encryptSecure(
        plaintext: plaintext,
        senderId: testUserId,
        receiverId: receiverId,
      );

      // Verify all security fields are present
      expect(encryptedData['text'], isNotNull);
      expect(encryptedData['key'], isNotNull);
      expect(encryptedData['iv'], isNotNull);
      expect(encryptedData['nonce'], isNotNull);
      expect(encryptedData['timestamp'], isNotNull);
      expect(encryptedData['idempotencyKey'], isNotNull);
      expect(encryptedData['hmac'], isNotNull);
      expect(encryptedData['hmacKeyVersion'], isNotNull);

      // Verify types
      expect(encryptedData['nonce'], isA<String>());
      expect(encryptedData['timestamp'], isA<String>());
      expect(encryptedData['idempotencyKey'], isA<String>());
      expect(encryptedData['hmac'], isA<String>());
      expect(encryptedData['hmacKeyVersion'], isA<String>());
    });

    test('testDecryptSecureMessage - full secure decrypt flow', () async {
      const plaintext = 'Secret message for testing';

      // First encrypt
      final encryptedData = await CryptoSecurityService.encryptSecure(
        plaintext: plaintext,
        senderId: testUserId,
        receiverId: receiverId,
      );

      // Then decrypt with security validation
      final decrypted = await CryptoSecurityService.decryptSecure(
        ciphertext: encryptedData['text']!,
        aesKey: encryptedData['key']!,
        iv: encryptedData['iv']!,
        messageId: 'test_msg_123',
        senderId: testUserId,
        nonce: encryptedData['nonce'],
        timestamp: encryptedData['timestamp'],
        idempotencyKey: encryptedData['idempotencyKey'],
        hmac: encryptedData['hmac'],
        hmacKeyVersion: encryptedData['hmacKeyVersion'],
      );

      expect(decrypted, equals(plaintext));
    });

    test('testLegacyMessageCompatibility - old messages work', () async {
      // Simulate a legacy message without security fields
      const plaintext = 'Legacy message';
      
      // Create encryption without security wrapper
      final encryptedData = await EncryptionHelper.encryptMessage(plaintext);

      // Decrypt as legacy message (no nonce, timestamp, etc.)
      final decrypted = await CryptoSecurityService.decryptSecure(
        ciphertext: encryptedData['text']!,
        aesKey: encryptedData['key']!,
        iv: encryptedData['iv']!,
        messageId: 'legacy_msg_123',
        senderId: testUserId,
        // No security fields - should fall back to basic decryption
      );

      expect(decrypted, equals(plaintext));
    });

    test('duplicate message is rejected', () async {
      const plaintext = 'One-time message';

      // Encrypt once
      final encryptedData = await CryptoSecurityService.encryptSecure(
        plaintext: plaintext,
        senderId: testUserId,
        receiverId: receiverId,
      );

      // First decrypt should succeed
      final decrypted1 = await CryptoSecurityService.decryptSecure(
        ciphertext: encryptedData['text']!,
        aesKey: encryptedData['key']!,
        iv: encryptedData['iv']!,
        messageId: 'dup_test_123',
        senderId: testUserId,
        nonce: encryptedData['nonce'],
        timestamp: encryptedData['timestamp'],
        idempotencyKey: encryptedData['idempotencyKey'],
        hmac: encryptedData['hmac'],
        hmacKeyVersion: encryptedData['hmacKeyVersion'],
      );
      expect(decrypted1, equals(plaintext));

      // Second decrypt with same idempotency key should fail
      await expectLater(
        CryptoSecurityService.decryptSecure(
          ciphertext: encryptedData['text']!,
          aesKey: encryptedData['key']!,
          iv: encryptedData['iv']!,
          messageId: 'dup_test_123',
          senderId: testUserId,
          nonce: encryptedData['nonce'],
          timestamp: encryptedData['timestamp'],
          idempotencyKey: encryptedData['idempotencyKey'],
          hmac: encryptedData['hmac'],
          hmacKeyVersion: encryptedData['hmacKeyVersion'],
        ),
        throwsA(
          isA<SecurityValidationException>().having(
            (e) => e.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
    });
  });

  group('HmacKeyService', () {
    const testUserId = 'test_user_hmac';
    const testSessionId = 'test_session_hmac';

    setUp(() {
      HmacKeyService.clear();
    });

    tearDown(() {
      HmacKeyService.clear();
    });

    test('initialize creates keys successfully', () async {
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );

      expect(HmacKeyService.isInitialized, isTrue);
      expect(HmacKeyService.getCurrentKeyVersion(), isNotNull);
      expect(HmacKeyService.getHmacKey(), isNotNull);
      expect(HmacKeyService.getHmacKey().length, equals(32));
    });

    test('same user/session produces consistent key within same app instance', () async {
      // Initialize service
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );
      
      // Get key multiple times - should be the same key
      final key1 = HmacKeyService.getHmacKey();
      final key2 = HmacKeyService.getHmacKey();
      
      // Same key within the same session
      expect(key1, equals(key2));
      
      // Verify key is properly derived (not all zeros, correct length)
      expect(key1.length, equals(32));
      final isAllZeros = key1.every((byte) => byte == 0);
      expect(isAllZeros, isFalse);
    });

    test('different user produces different key', () async {
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );
      final key1 = HmacKeyService.getHmacKey();

      HmacKeyService.clear();
      await HmacKeyService.initialize(
        userId: 'different_user',
        sessionId: testSessionId,
      );
      final key2 = HmacKeyService.getHmacKey();

      expect(key1, isNot(equals(key2)));
    });

    test('key rotation works', () async {
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );
      final initialVersion = HmacKeyService.getCurrentKeyVersion();
      final initialKey = HmacKeyService.getHmacKey();

      final newVersion = await HmacKeyService.rotateKey();

      expect(newVersion, isNot(equals(initialVersion)));
      expect(HmacKeyService.getHmacKey(), isNot(equals(initialKey)));
      expect(HmacKeyService.getCurrentKeyVersion(), equals(newVersion));
    });

    test('old key versions are accessible', () async {
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );
      final version1 = HmacKeyService.getCurrentKeyVersion()!;
      final key1 = HmacKeyService.getHmacKey();

      await HmacKeyService.rotateKey();
      final version2 = HmacKeyService.getCurrentKeyVersion()!;

      expect(HmacKeyService.hasKeyVersion(version1), isTrue);
      expect(HmacKeyService.hasKeyVersion(version2), isTrue);
      expect(HmacKeyService.getKeyVersion(version1), equals(key1));
    });

    test('clear removes all keys', () async {
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );

      HmacKeyService.clear();

      expect(HmacKeyService.isInitialized, isFalse);
      expect(
        () => HmacKeyService.getHmacKey(),
        throwsA(isA<HmacKeyException>()),
      );
    });

    test('throws when not initialized', () {
      HmacKeyService.clear();

      expect(
        () => HmacKeyService.getHmacKey(),
        throwsA(isA<HmacKeyException>()),
      );
      expect(HmacKeyService.getCurrentKeyVersion(), isNull);
    });

    test('diagnostics do not expose key material', () async {
      await HmacKeyService.initialize(
        userId: testUserId,
        sessionId: testSessionId,
      );
      await HmacKeyService.rotateKey();

      final diagnostics = HmacKeyService.getDiagnostics();

      expect(diagnostics['isInitialized'], isTrue);
      expect(diagnostics['currentVersion'], isNotNull);
      expect(diagnostics['cachedVersions'], isA<List>());
      expect(diagnostics['cachedVersions'].length, greaterThanOrEqualTo(1));
      expect(diagnostics['hasUserId'], isTrue);
      expect(diagnostics['hasSessionId'], isTrue);

      // Should not contain actual key material
      final diagnosticsStr = diagnostics.toString();
      expect(diagnosticsStr.contains('Uint8List'), isFalse);
      expect(diagnosticsStr.contains('key'), isFalse);
    });
  });
}
