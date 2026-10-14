import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';

import '../utils/encryption.dart';
import 'hmac_key_service.dart';

/// Enterprise-grade cryptographic security service
/// 
/// Provides:
/// - Replay attack protection via nonces and timestamps
/// - Message integrity verification via HMAC-SHA256
/// - Session validation and trust scoring
/// - Duplicate processing prevention via idempotency keys
/// - Key fingerprinting for trust verification
/// - Cryptographic message authentication
///
/// BACKWARD COMPATIBILITY: All new fields are optional and won't
/// break existing messages. Legacy messages continue to work.
class CryptoSecurityService {
  // Security constants
  static const _nonceBytes = 16;
  static const _sessionValidityHours = 24;
  static const _maxTimestampSkewMinutes = 5;
  static const _idempotencyWindowHours = 72;
  
  // Secure random for nonces
  static final _secureRandom = Random.secure();
  
  // Idempotency cache - prevents duplicate processing
  static final Set<String> _processedMessageIds = {};
  static DateTime? _cacheLastCleaned;
  
  // Session trust tracking
  static final Map<String, SessionTrustRecord> _sessionTrust = {};

  // ==========================================================================
  // REPLAY PROTECTION
  // ==========================================================================

  /// Generates a cryptographically secure nonce for replay protection
  /// 
  /// Each message gets a unique nonce that must be verified by the receiver.
  /// Combined with timestamp validation, this prevents replay attacks.
  static String generateNonce() {
    debugPrint('[CryptoSecurityService] generateNonce: START');
    final bytes = Uint8List(_nonceBytes);
    for (var i = 0; i < _nonceBytes; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    final nonce = base64Encode(bytes);
    debugPrint('[CryptoSecurityService] generateNonce: SUCCESS - nonce generated');
    debugPrint('[CryptoSecurityService] generateNonce: END');
    return nonce;
  }

  /// Validates that a nonce hasn't been used before (replay check)
  /// 
  /// Returns true if the nonce is valid (not seen before and not expired)
  static bool validateNonce(String nonce, DateTime timestamp) {
    debugPrint('[CryptoSecurityService] validateNonce: START - timestamp: ${timestamp.toIso8601String()}');
    try {
      // Check timestamp is within acceptable skew
      final now = DateTime.now().toUtc();
      final diff = now.difference(timestamp.toUtc()).abs();
      if (diff.inMinutes > _maxTimestampSkewMinutes) {
        debugPrint('[CryptoSecurityService] validateNonce: ERROR - timestamp too old: ${diff.inMinutes}m skew');
        throw SecurityValidationException(
          'Message timestamp too old: ${diff.inMinutes}m skew',
        );
      }
      
      // Check nonce hasn't been used
      final nonceKey = '${timestamp.toIso8601String()}_$nonce';
      if (_processedMessageIds.contains(nonceKey)) {
        debugPrint('[CryptoSecurityService] validateNonce: ERROR - nonce already used (possible replay)');
        throw SecurityValidationException('Nonce already used - possible replay');
      }
      
      debugPrint('[CryptoSecurityService] validateNonce: SUCCESS - nonce is valid');
      debugPrint('[CryptoSecurityService] validateNonce: END');
      return true;
    } catch (e) {
      debugPrint('[CryptoSecurityService] validateNonce: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  /// Marks a nonce as used to prevent replays
  static void markNonceUsed(String nonce, DateTime timestamp) {
    debugPrint('[CryptoSecurityService] markNonceUsed: START');
    final nonceKey = '${timestamp.toIso8601String()}_$nonce';
    _processedMessageIds.add(nonceKey);
    _cleanupNonceCache();
    debugPrint('[CryptoSecurityService] markNonceUsed: SUCCESS - nonce marked');
    debugPrint('[CryptoSecurityService] markNonceUsed: END');
  }

  /// Cleans up old nonces from the cache (72-hour window)
  static void _cleanupNonceCache() {
    if (_cacheLastCleaned != null && 
        DateTime.now().difference(_cacheLastCleaned!).inHours < 1) {
      return; // Only clean once per hour
    }
    
    debugPrint('[CryptoSecurityService] _cleanupNonceCache: START - cleaning old nonces');
    final cutoff = DateTime.now().toUtc().subtract(
      Duration(hours: _idempotencyWindowHours),
    );
    
    final beforeCount = _processedMessageIds.length;
    _processedMessageIds.removeWhere((key) {
      try {
        final timestamp = DateTime.parse(key.split('_')[0]);
        return timestamp.isBefore(cutoff);
      } catch (_) {
        return true; // Remove malformed entries
      }
    });
    final afterCount = _processedMessageIds.length;
    
    _cacheLastCleaned = DateTime.now();
    debugPrint('[CryptoSecurityService] _cleanupNonceCache: SUCCESS - cleaned ${beforeCount - afterCount} old nonces, remaining: $afterCount');
  }

  // ==========================================================================
  // HMAC KEY SERVICE INTEGRATION
  // ==========================================================================

  /// Gets the current HMAC key from the key service
  /// 
  /// Returns the derived HMAC key if available, null otherwise.
  /// This enables automatic HMAC computation when keys are available.
  static Uint8List? getCurrentHmacKey() {
    debugPrint('[CryptoSecurityService] getCurrentHmacKey: START');
    try {
      final key = HmacKeyService.getHmacKey();
      debugPrint('[CryptoSecurityService] getCurrentHmacKey: SUCCESS - key retrieved');
          debugPrint('[CryptoSecurityService] getCurrentHmacKey: END');
      return key;
    } catch (e) {
      debugPrint('[CryptoSecurityService] getCurrentHmacKey: ERROR - ${e.runtimeType}: $e');
      return null;
    }
  }

  /// Gets the current HMAC key version
  /// 
  /// This version should be included in message metadata so the
  /// receiver knows which key to use for verification.
  static String? getCurrentHmacKeyVersion() {
    debugPrint('[CryptoSecurityService] getCurrentHmacKeyVersion: START');
    final version = HmacKeyService.getCurrentKeyVersion();
    debugPrint('[CryptoSecurityService] getCurrentHmacKeyVersion: SUCCESS - version: $version');
    debugPrint('[CryptoSecurityService] getCurrentHmacKeyVersion: END');
    return version;
  }

  /// Checks if HMAC keys are available for use
  static bool get isHmacKeyAvailable {
    debugPrint('[CryptoSecurityService] isHmacKeyAvailable: START');
    final available = HmacKeyService.isInitialized;
    debugPrint('[CryptoSecurityService] isHmacKeyAvailable: SUCCESS - available: $available');
    debugPrint('[CryptoSecurityService] isHmacKeyAvailable: END');
    return available;
  }

  // ==========================================================================
  // MESSAGE INTEGRITY (HMAC)
  // ==========================================================================

  /// Computes HMAC-SHA256 for message integrity
  /// 
  /// The HMAC covers:
  /// - Encrypted message content (ciphertext)
  /// - AES key ciphertext
  /// - IV
  /// - Nonce
  /// - Timestamp
  /// - Sender ID
  /// 
  /// This ensures the message hasn't been tampered with in transit.
  /// 
  /// If keyMaterial is not provided, attempts to use the HmacKeyService.
  static Future<String> computeHmac({
    required String ciphertext,
    required String encryptedAesKey,
    required String iv,
    required String nonce,
    required DateTime timestamp,
    required String senderId,
    Uint8List? keyMaterial,
  }) async {
    debugPrint('[CryptoSecurityService] computeHmac: START - senderId: $senderId');
    try {
      // Use provided key or try to get from key service
      final key = keyMaterial ?? getCurrentHmacKey();
      
      if (key == null) {
        debugPrint('[CryptoSecurityService] computeHmac: ERROR - no HMAC key available');
        throw SecurityValidationException(
          'No HMAC key available. Initialize HmacKeyService first.',
        );
      }

      // Build canonical message representation
      final message = _canonicalizeMessage(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
      );
      
      // Compute HMAC-SHA256
      final hmac = HMac(SHA256Digest(), 64);
      hmac.init(KeyParameter(key));
      hmac.update(utf8.encode(message), 0, message.length);
      
      final mac = Uint8List(32);
      hmac.doFinal(mac, 0);
      
      final hmacBase64 = base64Encode(mac);
      debugPrint('[CryptoSecurityService] computeHmac: SUCCESS - HMAC computed');
      debugPrint('[CryptoSecurityService] computeHmac: END');
      return hmacBase64;
    } catch (e) {
      debugPrint('[CryptoSecurityService] computeHmac: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  /// Verifies HMAC for message integrity
  /// 
  /// Returns true if the message integrity is verified, false otherwise.
  /// Throws SecurityValidationException for critical failures.
  /// 
  /// If keyMaterial is not provided, attempts to use the HmacKeyService.
  static Future<bool> verifyHmac({
    required String ciphertext,
    required String encryptedAesKey,
    required String iv,
    required String nonce,
    required DateTime timestamp,
    required String senderId,
    required String expectedHmac,
    String? hmacKeyVersion,
    Uint8List? keyMaterial,
  }) async {
    debugPrint('[CryptoSecurityService] verifyHmac: START - senderId: $senderId');
    try {
      // Use provided key, try key service with specific version, or current key
      Uint8List? key;
      if (keyMaterial != null) {
        debugPrint('[CryptoSecurityService] verifyHmac: using provided key');
        key = keyMaterial;
      } else if (hmacKeyVersion != null) {
        debugPrint('[CryptoSecurityService] verifyHmac: looking up key by version: $hmacKeyVersion');
        key = HmacKeyService.getKeyVersion(hmacKeyVersion);
        if (key != null) {
          debugPrint('[CryptoSecurityService] verifyHmac: key found for version: $hmacKeyVersion');
        }
      } else {
        debugPrint('[CryptoSecurityService] verifyHmac: using current HMAC key');
        key = getCurrentHmacKey();
      }
      
      if (key == null) {
        debugPrint('[CryptoSecurityService] verifyHmac: ERROR - no HMAC key available for verification');
        throw SecurityValidationException(
          'No HMAC key available for verification',
        );
      }

      final computed = await computeHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        keyMaterial: key,
      );
      
      // Constant-time comparison to prevent timing attacks
      if (!_constantTimeCompare(computed, expectedHmac)) {
        debugPrint('[CryptoSecurityService] verifyHmac: ERROR - HMAC mismatch, message may be tampered');
        throw SecurityValidationException(
          'Message integrity verification failed - possible tampering',
        );
      }
      
      debugPrint('[CryptoSecurityService] verifyHmac: SUCCESS - HMAC verified');
      debugPrint('[CryptoSecurityService] verifyHmac: END');
      return true;
    } catch (e) {
      debugPrint('[CryptoSecurityService] verifyHmac: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  /// Verifies HMAC for message integrity (public alias for verifyHmac)
  static Future<bool> verifyMessageHmac({
    required String ciphertext,
    required String encryptedAesKey,
    required String iv,
    required String nonce,
    required DateTime timestamp,
    required String senderId,
    required String expectedHmac,
    String? hmacKeyVersion,
    Uint8List? keyMaterial,
  }) async {
    debugPrint('[CryptoSecurityService] verifyMessageHmac: START - senderId: $senderId');
    try {
      final result = await verifyHmac(
        ciphertext: ciphertext,
        encryptedAesKey: encryptedAesKey,
        iv: iv,
        nonce: nonce,
        timestamp: timestamp,
        senderId: senderId,
        expectedHmac: expectedHmac,
        hmacKeyVersion: hmacKeyVersion,
        keyMaterial: keyMaterial,
      );
      debugPrint('[CryptoSecurityService] verifyMessageHmac: SUCCESS - HMAC verified');
      debugPrint('[CryptoSecurityService] verifyMessageHmac: END');
      return result;
    } catch (e) {
      debugPrint('[CryptoSecurityService] verifyMessageHmac: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  /// Calculates a hash of the message for integrity checking
  static String calculateMessageHash(String message) {
    debugPrint('[CryptoSecurityService] calculateMessageHash: START');
    try {
      final digest = SHA256Digest();
      final hash = digest.process(Uint8List.fromList(utf8.encode(message)));
      final hashBase64 = base64Encode(hash);
      debugPrint('[CryptoSecurityService] calculateMessageHash: SUCCESS - hash calculated');
      debugPrint('[CryptoSecurityService] calculateMessageHash: END');
      return hashBase64;
    } catch (e) {
      debugPrint('[CryptoSecurityService] calculateMessageHash: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  // ==========================================================================
  // IDEMPOTENCY (DUPLICATE PREVENTION)
  // ==========================================================================

  /// Generates an idempotency key for a message
  /// 
  /// This key uniquely identifies a message and prevents duplicate
  /// processing across sessions, reconnects, and retries.
  static String generateIdempotencyKey({
    required String senderId,
    required String receiverId,
    required DateTime timestamp,
    required String nonce,
  }) {
    debugPrint('[CryptoSecurityService] generateIdempotencyKey: START - senderId: $senderId, receiverId: $receiverId');
    final data = '$senderId:$receiverId:${timestamp.millisecondsSinceEpoch}:$nonce';
    final digest = SHA256Digest();
    final hash = digest.process(Uint8List.fromList(utf8.encode(data)));
    final key = base64Encode(hash);
    debugPrint('[CryptoSecurityService] generateIdempotencyKey: SUCCESS - key generated');
    debugPrint('[CryptoSecurityService] generateIdempotencyKey: END');
    return key;
  }

  /// Checks if a message has already been processed
  static bool isMessageProcessed(String idempotencyKey) {
    debugPrint('[CryptoSecurityService] isMessageProcessed: START');
    final isProcessed = _processedMessageIds.contains(idempotencyKey);
    debugPrint('[CryptoSecurityService] isMessageProcessed: SUCCESS - isProcessed: $isProcessed');
    debugPrint('[CryptoSecurityService] isMessageProcessed: END');
    return isProcessed;
  }

  /// Marks a message as processed
  static void markMessageProcessed(String idempotencyKey) {
    debugPrint('[CryptoSecurityService] markMessageProcessed: START');
    _processedMessageIds.add(idempotencyKey);
    _cleanupNonceCache();
    debugPrint('[CryptoSecurityService] markMessageProcessed: SUCCESS - message marked as processed');
    debugPrint('[CryptoSecurityService] markMessageProcessed: END');
  }

  // ==========================================================================
  // SESSION TRUST VALIDATION
  // ==========================================================================

  /// Validates session trust level before cryptographic operations
  /// 
  /// Checks:
  /// - Session age (not expired)
  /// - Key version compatibility
  /// - Trust score (based on successful operations)
  /// - Last activity (not stale)
  static SessionValidationResult validateSession({
    required String userId,
    required String? keyVersion,
    required DateTime? sessionCreated,
    required DateTime? lastActivity,
    required String? expectedKeyVersion,
  }) {
    debugPrint('[CryptoSecurityService] validateSession: START - userId: $userId, keyVersion: $keyVersion');
    final issues = <String>[];
    var trustScore = 100;
    
    // Check session age
    if (sessionCreated != null) {
      final age = DateTime.now().difference(sessionCreated);
      if (age.inHours > _sessionValidityHours) {
        trustScore -= 40;
        issues.add('Session expired (${age.inHours}h old)');
        debugPrint('[CryptoSecurityService] validateSession: session expired - age: ${age.inHours}h');
      } else if (age.inHours > _sessionValidityHours ~/ 2) {
        trustScore -= 10;
        issues.add('Session aging (${age.inHours}h old)');
        debugPrint('[CryptoSecurityService] validateSession: session aging - age: ${age.inHours}h');
      }
    }
    
    // Check key version compatibility
    if (expectedKeyVersion != null && keyVersion != expectedKeyVersion) {
      trustScore -= 50;
      issues.add('Key version mismatch: $keyVersion vs $expectedKeyVersion');
      debugPrint('[CryptoSecurityService] validateSession: key version mismatch - $keyVersion vs $expectedKeyVersion');
    }
    
    // Check activity staleness
    if (lastActivity != null) {
      final inactive = DateTime.now().difference(lastActivity);
      if (inactive.inHours > 12) {
        trustScore -= 20;
        issues.add('Session stale (${inactive.inHours}h inactive)');
        debugPrint('[CryptoSecurityService] validateSession: session stale - inactive: ${inactive.inHours}h');
      }
    }
    
    // Check trust record
    final trustRecord = _sessionTrust[userId];
    if (trustRecord != null) {
      if (trustRecord.failedDecryptionCount > 5) {
        trustScore -= 30;
        issues.add('Multiple decryption failures');
        debugPrint('[CryptoSecurityService] validateSession: multiple decryption failures - count: ${trustRecord.failedDecryptionCount}');
      }
      if (trustRecord.lastMismatchTime != null) {
        final sinceMismatch = DateTime.now().difference(trustRecord.lastMismatchTime!);
        if (sinceMismatch.inMinutes < 30) {
          trustScore -= 20;
          issues.add('Recent key mismatch');
          debugPrint('[CryptoSecurityService] validateSession: recent key mismatch - ${sinceMismatch.inMinutes}m ago');
        }
      }
    }
    
    final result = SessionValidationResult(
      isValid: trustScore > 50,
      trustScore: trustScore,
      issues: issues,
      recommendation: trustScore < 30 
          ? SessionRecommendation.rotateKeys 
          : trustScore < 70 
              ? SessionRecommendation.revalidate 
              : SessionRecommendation.continueSession,
    );
    
    debugPrint('[CryptoSecurityService] validateSession: SUCCESS - trustScore: $trustScore, isValid: ${result.isValid}, issues: ${issues.length}');
    debugPrint('[CryptoSecurityService] validateSession: END');
    return result;
  }

  // ==========================================================================
  // KEY FINGERPRINTING (TRUST VERIFICATION)
  // ==========================================================================

  /// Computes a fingerprint of a public key for trust verification
  /// 
  /// This allows users to verify they're using the correct key
  /// out-of-band (e.g., via QR code comparison).
  static String computeKeyFingerprint(String publicKeyPem) {
    debugPrint('[CryptoSecurityService] computeKeyFingerprint: START');
    final digest = SHA256Digest();
    final hash = digest.process(Uint8List.fromList(utf8.encode(publicKeyPem)));
    
    // Return first 16 bytes as base64 (128 bits of security)
    final fingerprint = base64Encode(hash.sublist(0, 16));
    
    // Format for readability: XXXX-XXXX-XXXX-XXXX
    final formatted = fingerprint.replaceAllMapped(
      RegExp(r'.{4}'),
      (match) => '${match.group(0)}-',
    ).substring(0, 19);
    debugPrint('[CryptoSecurityService] computeKeyFingerprint: SUCCESS - fingerprint computed');
    debugPrint('[CryptoSecurityService] computeKeyFingerprint: END');
    return formatted;
  }

  /// Verifies that a key fingerprint matches expected value
  static bool verifyKeyFingerprint(String publicKeyPem, String expectedFingerprint) {
    debugPrint('[CryptoSecurityService] verifyKeyFingerprint: START');
    final computed = computeKeyFingerprint(publicKeyPem);
    final isValid = _constantTimeCompare(computed.replaceAll('-', ''), 
                            expectedFingerprint.replaceAll('-', ''));
    debugPrint('[CryptoSecurityService] verifyKeyFingerprint: SUCCESS - isValid: $isValid');
    debugPrint('[CryptoSecurityService] verifyKeyFingerprint: END');
    return isValid;
  }

  // ==========================================================================
  // RECONNECT SECURITY
  // ==========================================================================

  /// Validates that a reconnect is legitimate (not session hijacking)
  /// 
  /// Called when app reconnects after being offline.
  /// Validates session continuity.
  static Future<ReconnectValidationResult> validateReconnect({
    required String userId,
    required DateTime? lastKnownSessionTime,
    required String? lastKnownKeyVersion,
    required String? currentKeyVersion,
  }) async {
    debugPrint('[CryptoSecurityService] validateReconnect: START - userId: $userId');
    final issues = <String>[];
    var trustScore = 100;
    
    // Check if keys changed while offline
    if (lastKnownKeyVersion != null && currentKeyVersion != lastKnownKeyVersion) {
      trustScore -= 30;
      issues.add('Keys rotated while offline: $lastKnownKeyVersion → $currentKeyVersion');
      debugPrint('[CryptoSecurityService] validateReconnect: keys rotated while offline');
    }
    
    // Check session age
    if (lastKnownSessionTime != null) {
      final offlineDuration = DateTime.now().difference(lastKnownSessionTime);
      if (offlineDuration.inHours > 24) {
        trustScore -= 20;
        issues.add('Extended offline period: ${offlineDuration.inHours}h');
        debugPrint('[CryptoSecurityService] validateReconnect: extended offline period');
      }
    }
    
    // Check for suspicious activity (multiple rapid reconnects)
    final trustRecord = _sessionTrust[userId];
    if (trustRecord != null && trustRecord.reconnectCount > 10) {
      final recentReconnects = trustRecord.reconnectTimes.where(
        (t) => DateTime.now().difference(t).inMinutes < 5,
      ).length;
      if (recentReconnects > 3) {
        trustScore -= 25;
        issues.add('Suspicious reconnect pattern: $recentReconnects recent');
        debugPrint('[CryptoSecurityService] validateReconnect: suspicious reconnect pattern');
      }
    }
    
    // Update reconnect tracking
    _sessionTrust[userId] ??= SessionTrustRecord();
    _sessionTrust[userId]!.reconnectCount++;
    _sessionTrust[userId]!.reconnectTimes.add(DateTime.now());
    
    // Trim old reconnect times (keep last 100)
    if (_sessionTrust[userId]!.reconnectTimes.length > 100) {
      _sessionTrust[userId]!.reconnectTimes.removeAt(0);
    }
    
    final result = ReconnectValidationResult(
      isValid: trustScore > 50,
      trustScore: trustScore,
      issues: issues,
      shouldRevalidateKeys: trustScore < 70 || lastKnownKeyVersion != currentKeyVersion,
    );
    
    debugPrint('[CryptoSecurityService] validateReconnect: SUCCESS - trustScore: $trustScore, isValid: ${result.isValid}');
    debugPrint('[CryptoSecurityService] validateReconnect: END');
    return result;
  }

  // ==========================================================================
  // ENHANCED ENCRYPT/DECRYPT WITH SECURITY
  // ==========================================================================

  /// Encrypts a message with full security features
  /// 
  /// Adds:
  /// - Replay protection (nonce)
  /// - Integrity protection (HMAC)
  /// - Timestamp validation
  /// - Idempotency key
  /// - HMAC key version tracking
  /// 
  /// BACKWARD COMPATIBILITY: All security fields are optional in the
  /// returned map. Legacy code can ignore them.
  /// 
  /// If hmacKey is not provided, automatically uses HmacKeyService if available.
  static Future<Map<String, dynamic>> encryptSecure({
    required String plaintext,
    required String senderId,
    required String receiverId,
    Uint8List? hmacKey,
    bool skipHmacIfNoKey = false,
  }) async {
    debugPrint('[CryptoSecurityService] encryptSecure: START - senderId: $senderId, receiverId: $receiverId');
    try {
      // Generate standard encryption
      debugPrint('[CryptoSecurityService] encryptSecure: encrypting message');
      final encrypted = await EncryptionHelper.encryptMessage(plaintext);
      
      // Generate security fields
      debugPrint('[CryptoSecurityService] encryptSecure: generating security fields');
      final nonce = generateNonce();
      final timestamp = DateTime.now().toUtc();
      final idempotencyKey = generateIdempotencyKey(
        senderId: senderId,
        receiverId: receiverId,
        timestamp: timestamp,
        nonce: nonce,
      );
      
      // Get HMAC key (use provided, or try service, or null)
      final key = hmacKey ?? getCurrentHmacKey();
      final keyVersion = getCurrentHmacKeyVersion();
      
      // Compute HMAC if key material available
      String? hmac;
      if (key != null) {
        debugPrint('[CryptoSecurityService] encryptSecure: computing HMAC');
        hmac = await computeHmac(
          ciphertext: encrypted['text']!,
          encryptedAesKey: encrypted['key']!,
          iv: encrypted['iv']!,
          nonce: nonce,
          timestamp: timestamp,
          senderId: senderId,
          keyMaterial: key,
        );
        debugPrint('[CryptoSecurityService] encryptSecure: HMAC computed successfully');
      } else if (!skipHmacIfNoKey) {
        debugPrint('[CryptoSecurityService] encryptSecure: WARNING - HMAC skipped, no key available');
      }
      
      final result = {
        ...encrypted,
        'nonce': nonce,
        'timestamp': timestamp.toIso8601String(),
        'idempotencyKey': idempotencyKey,
        'hmac': ?hmac,
        'hmacKeyVersion': ?keyVersion,
      };
      debugPrint('[CryptoSecurityService] encryptSecure: SUCCESS - encryption complete');
      debugPrint('[CryptoSecurityService] encryptSecure: END');
      return result;
    } catch (e) {
      debugPrint('[CryptoSecurityService] encryptSecure: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  /// Decrypts a message with full security validation
  /// 
  /// Validates:
  /// - Replay protection (nonce uniqueness)
  /// - Integrity protection (HMAC)
  /// - Timestamp (not expired)
  /// - Idempotency (not duplicate)
  /// - HMAC key version compatibility
  /// 
  /// BACKWARD COMPATIBILITY: Handles legacy messages without security fields.
  static Future<String> decryptSecure({
    required String ciphertext,
    required String aesKey,
    required String iv,
    required String messageId,
    required String senderId,
    String? nonce,
    String? timestamp,
    String? idempotencyKey,
    String? hmac,
    String? hmacKeyVersion,
    Uint8List? hmacKey,
    bool skipHmacVerification = false,
  }) async {
    debugPrint('[CryptoSecurityService] decryptSecure: START - messageId: $messageId, senderId: $senderId');
    try {
      // Legacy message support: if no security fields, just decrypt
      if (nonce == null || timestamp == null) {
        debugPrint('[CryptoSecurityService] decryptSecure: legacy message detected, simple decryption');
        final result = await EncryptionHelper.decryptMessage(ciphertext, aesKey, iv);
        debugPrint('[CryptoSecurityService] decryptSecure: SUCCESS - legacy message decrypted');
        debugPrint('[CryptoSecurityService] decryptSecure: END');
        return result;
      }
      
      // Parse timestamp
      final ts = DateTime.parse(timestamp);
      
      // Validate idempotency
      final ikey = idempotencyKey ?? '${senderId}_$messageId';
      debugPrint('[CryptoSecurityService] decryptSecure: validating idempotency');
      if (isMessageProcessed(ikey)) {
        debugPrint('[CryptoSecurityService] decryptSecure: ERROR - duplicate message');
        throw SecurityValidationException(
          'Message already processed (duplicate)',
        );
      }
      
      // Validate replay protection
      debugPrint('[CryptoSecurityService] decryptSecure: validating replay protection');
      validateNonce(nonce, ts);
      
      // Verify HMAC if provided
      if (hmac != null && !skipHmacVerification) {
        debugPrint('[CryptoSecurityService] decryptSecure: verifying HMAC');
        Uint8List? key = hmacKey;
        
        if (key == null && hmacKeyVersion != null) {
          key = HmacKeyService.getKeyVersion(hmacKeyVersion);
        }
        
        key ??= getCurrentHmacKey();
        
        if (key != null) {
          await verifyHmac(
            ciphertext: ciphertext,
            encryptedAesKey: aesKey,
            iv: iv,
            nonce: nonce,
            timestamp: ts,
            senderId: senderId,
            hmacKeyVersion: hmacKeyVersion,
            keyMaterial: key,
            expectedHmac: hmac,
          );
          debugPrint('[CryptoSecurityService] decryptSecure: HMAC verified');
        } else {
          debugPrint('[CryptoSecurityService] decryptSecure: WARNING - Cannot verify HMAC, no key available');
        }
      }
      
      // Mark as processed
      markMessageProcessed(ikey);
      markNonceUsed(nonce, ts);
      
      // Decrypt
      debugPrint('[CryptoSecurityService] decryptSecure: decrypting message');
      final result = await EncryptionHelper.decryptMessage(ciphertext, aesKey, iv);
      debugPrint('[CryptoSecurityService] decryptSecure: SUCCESS - message decrypted');
      debugPrint('[CryptoSecurityService] decryptSecure: END');
      return result;
    } catch (e) {
      debugPrint('[CryptoSecurityService] decryptSecure: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
  }

  // ==========================================================================
  // HELPERS
  // ==========================================================================

  /// Creates canonical message representation for HMAC
  static String _canonicalizeMessage({
    required String ciphertext,
    required String encryptedAesKey,
    required String iv,
    required String nonce,
    required DateTime timestamp,
    required String senderId,
  }) {
    final parts = [
      ciphertext,
      encryptedAesKey,
      iv,
      nonce,
      timestamp.toIso8601String(),
      senderId,
    ];
    return parts.join('|');
  }

  /// Constant-time comparison to prevent timing attacks
  static bool _constantTimeCompare(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}

// ============================================================================
// DATA CLASSES
// ============================================================================

class SessionValidationResult {
  final bool isValid;
  final int trustScore;
  final List<String> issues;
  final SessionRecommendation recommendation;
  
  const SessionValidationResult({
    required this.isValid,
    required this.trustScore,
    required this.issues,
    required this.recommendation,
  });
  
  bool get shouldContinue => isValid && trustScore >= 70;
  bool get needsAttention => trustScore < 70 && trustScore >= 50;
  bool get isCompromised => trustScore < 50;
}

/// Alias for SessionRecommendation - use this from security service
enum SessionRecommendation {
  continueSession,
  revalidate,
  rotateKeys,
}

class SessionTrustRecord {
  int successfulDecryptionCount = 0;
  int failedDecryptionCount = 0;
  DateTime? lastMismatchTime;
  DateTime? lastActivityTime;
  int reconnectCount = 0;
  final List<DateTime> reconnectTimes = [];
}

class ReconnectValidationResult {
  final bool isValid;
  final int trustScore;
  final List<String> issues;
  final bool shouldRevalidateKeys;
  
  const ReconnectValidationResult({
    required this.isValid,
    required this.trustScore,
    required this.issues,
    required this.shouldRevalidateKeys,
  });
}

class SecurityValidationException implements Exception {
  final String message;
  
  const SecurityValidationException(this.message);
  
  @override
  String toString() => 'SecurityValidationException: $message';
}
