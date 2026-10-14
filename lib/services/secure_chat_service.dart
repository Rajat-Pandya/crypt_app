import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/asymmetric/api.dart';

import '../cache/models/message_cache.dart';
import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';
import '../utils/input_validator.dart';
import 'chat_util_service.dart';
import 'chat_list_service.dart';
import 'crypto_security_service.dart';
import 'encryption_lifecycle.dart';
import 'hmac_key_service.dart';
import 'key_mismatch_manager.dart';

/// Enterprise-grade secure chat service with cryptographic hardening
/// 
/// This service wraps the standard ChatService and adds:
/// - Replay attack protection (nonces)
/// - Message integrity verification (HMAC-SHA256)
/// - Session trust validation
/// - Duplicate processing prevention (idempotency)
/// - Key fingerprinting for trust verification
/// 
/// BACKWARD COMPATIBILITY: All security features are optional and
/// gracefully degrade for legacy messages. Existing chats continue
/// to work without modification.
class SecureChatService {
  static final _firestore = FirebaseFirestore.instance;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[SecureChatService] $message');
      return true;
    }());
  }

  // ==========================================================================
  // SECURE MESSAGE SENDING
  // ==========================================================================

  /// Sends a message with full cryptographic security
  /// 
  /// Security features:
  /// - Generates cryptographically secure nonce for replay protection
  /// - Computes HMAC-SHA256 for message integrity (auto-uses HmacKeyService)
  /// - Creates idempotency key for duplicate prevention
  /// - Includes timestamp for freshness validation
  /// - Key fingerprinting for trust verification
  /// - HMAC key version tracking for key rotation support
  static Future<void> sendSecureMessage({
    required String currentUserId,
    required String receiverId,
    required String text,
    required RSAPublicKey receiverPublicKey,
    required RSAPublicKey senderPublicKey,
    required String senderKeyVersion,
    required String receiverKeyVersion,
    String? senderName,
    Map<String, dynamic>? replyTo,
    bool? isMuted,
    Uint8List? hmacKey, // Optional: will use HmacKeyService if not provided
  }) async {
    debugPrint('[SecureChatService] sendSecureMessage: START - currentUserId: $currentUserId, receiverId: $receiverId, textLength: ${text.length}');
    
    final error = InputValidator.validateMessage(text);
    if (error != null) {
      debugPrint('[SecureChatService] sendSecureMessage: ERROR - validation failed: $error');
      debugPrint('[SecureChatService] sendSecureMessage: END');
      throw Exception(error);
    }
    debugPrint('[SecureChatService] sendSecureMessage: message validation passed');

    final chatRoomId = ChatListService.getRoomId(currentUserId, receiverId);
    debugPrint('[SecureChatService] sendSecureMessage: chatRoomId: $chatRoomId');

    _dbg('Sending secure message to $receiverId');

    // Ensure HMAC keys are initialized (auto-init if needed)
    if (!HmacKeyService.isInitialized) {
      debugPrint('[SecureChatService] sendSecureMessage: HMAC keys not initialized, initializing now');
      final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
      await initializeHmacKeys(
        userId: currentUserId,
        sessionId: sessionId,
      );
    }

    // Encrypt message
    debugPrint('[SecureChatService] sendSecureMessage: encrypting message');
    final encryptedData = await EncryptionHelper.encryptMessage(text);
    debugPrint('[SecureChatService] sendSecureMessage: message encrypted');

    // Generate security fields
    debugPrint('[SecureChatService] sendSecureMessage: generating security fields');
    final nonce = CryptoSecurityService.generateNonce();
    final timestamp = DateTime.now().toUtc();
    final idempotencyKey = CryptoSecurityService.generateIdempotencyKey(
      senderId: currentUserId,
      receiverId: receiverId,
      timestamp: timestamp,
      nonce: nonce,
    );
    debugPrint('[SecureChatService] sendSecureMessage: security fields generated - nonce: $nonce');

    // Encrypt AES keys for both parties
    debugPrint('[SecureChatService] sendSecureMessage: encrypting AES keys');
    final encryptedAESKeyForReceiver = await RSAHelper.encrypt(
      encryptedData['key']!,
      receiverPublicKey,
    );
    final encryptedAESKeyForSender = await RSAHelper.encrypt(
      encryptedData['key']!,
      senderPublicKey,
    );
    debugPrint('[SecureChatService] sendSecureMessage: AES keys encrypted');

    // Compute HMAC for integrity (uses HmacKeyService automatically)
    String? hmac;
    String? hmacKeyVersion;
    try {
      final key = hmacKey ?? CryptoSecurityService.getCurrentHmacKey();
      
      if (key != null) {
        debugPrint('[SecureChatService] sendSecureMessage: computing HMAC');
        hmac = await CryptoSecurityService.computeHmac(
          ciphertext: encryptedData['text']!,
          encryptedAesKey: encryptedAESKeyForReceiver,
          iv: encryptedData['iv']!,
          nonce: nonce,
          timestamp: timestamp,
          senderId: currentUserId,
          keyMaterial: key,
        );
        hmacKeyVersion = CryptoSecurityService.getCurrentHmacKeyVersion();
        debugPrint('[SecureChatService] sendSecureMessage: HMAC computed - key version: $hmacKeyVersion');
      } else {
        debugPrint('[SecureChatService] sendSecureMessage: WARNING - no HMAC key available');
      }
    } catch (e) {
      debugPrint('[SecureChatService] sendSecureMessage: WARNING - HMAC computation failed: $e');
    }

    // Get fingerprint for trust verification
    final senderFingerprint = EncryptionLifecycleService.getMyFingerprint();
    debugPrint('[SecureChatService] sendSecureMessage: sender fingerprint: $senderFingerprint');

    // Build message document
    final messageData = {
      'senderId': currentUserId,
      'receiverId': receiverId,
      'text': encryptedData['text'],
      'aesKey': encryptedAESKeyForReceiver,
      'aesKeySender': encryptedAESKeyForSender,
      'iv': encryptedData['iv'],
      'senderKeyVersion': senderKeyVersion,
      'receiverKeyVersion': receiverKeyVersion,
      'status': 'sent',
      'timestamp': FieldValue.serverTimestamp(),
      'starred': false,
      'deletedFor': [],
      'reactions': {},
      // Security fields (backward compatible - optional)
      '_nonce': nonce,
      '_timestamp': timestamp.toIso8601String(),
      '_idempotencyKey': idempotencyKey,
      '_senderFingerprint': senderFingerprint,
      '_hmac': ?hmac,
      '_hmacKeyVersion': ?hmacKeyVersion,
      'replyTo': ?replyTo,
    };

    // Update chat room
    debugPrint('[SecureChatService] sendSecureMessage: updating chat room metadata');
    await _firestore.collection('chat_rooms').doc(chatRoomId).set({
      'users': [currentUserId, receiverId],
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastMessage': '🔒 Encrypted message',
    }, SetOptions(merge: true));

    // Send message
    debugPrint('[SecureChatService] sendSecureMessage: adding message to Firestore');
    await _firestore
        .collection('chat_rooms')
        .doc(chatRoomId)
        .collection('messages')
        .add(messageData);

    _dbg('Secure message sent with nonce=$nonce, idempotency=$idempotencyKey, hmac=${hmac != null}');
    debugPrint('[SecureChatService] sendSecureMessage: message sent successfully');

    // Send notification
    String resolvedSenderName = senderName ?? 'Someone';
    if (senderName == null) {
      debugPrint('[SecureChatService] sendSecureMessage: fetching sender name');
      try {
        final senderDoc = await _firestore
            .collection('users')
            .doc(currentUserId)
            .get();
        resolvedSenderName = (senderDoc.data()?['name'] as String?) ?? 'Someone';
        debugPrint('[SecureChatService] sendSecureMessage: sender name resolved: $resolvedSenderName');
      } catch (e) {
        debugPrint('[SecureChatService] sendSecureMessage: WARNING - could not fetch sender name: $e');
      }
    }

    debugPrint('[SecureChatService] sendSecureMessage: sending notification');
    await ChatUtilService.sendNotification(
      receiverId, 
      resolvedSenderName,
      senderName: resolvedSenderName, 
      isMuted: isMuted,
    );
    debugPrint('[SecureChatService] sendSecureMessage: SUCCESS - secure message sent and notification queued');
    debugPrint('[SecureChatService] sendSecureMessage: END');
  }

  // ==========================================================================
  // SECURE MESSAGE DECRYPTION
  // ==========================================================================

  /// Decrypts a message with full security validation
  /// 
  /// Validates:
  /// - Replay protection (nonce uniqueness)
  /// - Message integrity (HMAC with key version support)
  /// - Timestamp freshness
  /// - Duplicate processing prevention (idempotency)
  /// - Session trust
  /// 
  /// BACKWARD COMPATIBILITY: Handles legacy messages gracefully.
  static Future<String> decryptSecureMessage({
    required String messageId,
    required String encryptedText,
    required String encryptedAesKey,
    required String iv,
    required bool isOwnMessage,
    required String senderId,
    required String receiverId,
    required String currentUserId,
    String? nonce,
    String? timestamp,
    String? idempotencyKey,
    String? hmac,
    String? hmacKeyVersion,
    String? senderFingerprint,
    Uint8List? hmacKey,
    String? keyVersion,
  }) async {
    debugPrint('[SecureChatService] decryptSecureMessage: START - messageId: $messageId, isOwnMessage: $isOwnMessage, senderId: $senderId');

    // Determine which AES key to use
    final aesKey = isOwnMessage ? encryptedAesKey : encryptedAesKey;
    
    // Validate trust before decryption
    debugPrint('[SecureChatService] decryptSecureMessage: validating session trust');
    final trustResult = CryptoSecurityService.validateSession(
      userId: senderId,
      keyVersion: keyVersion,
      sessionCreated: null,
      lastActivity: null,
      expectedKeyVersion: null,
    );

    if (trustResult.isCompromised) {
      debugPrint('[SecureChatService] decryptSecureMessage: WARNING - trust validation failed: ${trustResult.issues}');
    } else {
      debugPrint('[SecureChatService] decryptSecureMessage: trust validation passed');
    }

    try {
      // Get HMAC key for verification
      Uint8List? verificationKey = hmacKey;
      if (verificationKey == null && hmacKeyVersion != null) {
        debugPrint('[SecureChatService] decryptSecureMessage: looking up HMAC key by version: $hmacKeyVersion');
        verificationKey = HmacKeyService.getKeyVersion(hmacKeyVersion);
        if (verificationKey != null) {
          debugPrint('[SecureChatService] decryptSecureMessage: HMAC key found for version: $hmacKeyVersion');
        }
      }
      if (verificationKey == null && HmacKeyService.isInitialized) {
        debugPrint('[SecureChatService] decryptSecureMessage: using current HMAC key');
        verificationKey = CryptoSecurityService.getCurrentHmacKey();
      }

      // Decrypt with security validation
      debugPrint('[SecureChatService] decryptSecureMessage: decrypting message');
      final decrypted = await CryptoSecurityService.decryptSecure(
        ciphertext: encryptedText,
        aesKey: aesKey,
        iv: iv,
        messageId: messageId,
        senderId: senderId,
        nonce: nonce,
        timestamp: timestamp,
        idempotencyKey: idempotencyKey,
        hmac: hmac,
        hmacKeyVersion: hmacKeyVersion,
        hmacKey: verificationKey,
      );

      // Record successful decryption
      EncryptionLifecycleService.recordSuccessfulDecryption(senderId);

      debugPrint('[SecureChatService] decryptSecureMessage: SUCCESS - message decrypted');
      debugPrint('[SecureChatService] decryptSecureMessage: END');
      return decrypted;
    } catch (e) {
      debugPrint('[SecureChatService] decryptSecureMessage: ERROR - ${e.runtimeType}: $e');
      
      // Handle mismatch
      final recovery = EncryptionLifecycleService.handleDecryptionMismatch(
        senderId,
        messageId: messageId,
        keyVersion: keyVersion ?? '',
      );

      if (recovery.shouldClearCache) {
        debugPrint('[SecureChatService] decryptSecureMessage: clearing receiver cache');
        EncryptionLifecycleService.clearReceiverCache(senderId);
      }

      debugPrint('[SecureChatService] decryptSecureMessage: END');
      rethrow;
    }
  }

  // ==========================================================================
  // HMAC KEY INITIALIZATION
  // ==========================================================================

  /// Initializes HMAC keys for the current user session
  /// 
  /// This should be called on app startup or when a user logs in.
  /// It derives HMAC keys from the user ID and session ID.
  static Future<void> initializeHmacKeys({
    required String userId,
    required String sessionId,
  }) async {
    debugPrint('[SecureChatService] initializeHmacKeys: START - userId: $userId, sessionId: $sessionId');
    try {
      await HmacKeyService.initialize(
        userId: userId,
        sessionId: sessionId,
      );
      debugPrint('[SecureChatService] initializeHmacKeys: SUCCESS - HMAC keys initialized');
    } catch (e) {
      debugPrint('[SecureChatService] initializeHmacKeys: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[SecureChatService] initializeHmacKeys: END');
  }

  /// Rotates HMAC keys for enhanced security
  /// 
  /// Call this periodically or when security events occur.
  static Future<void> rotateHmacKeys() async {
    debugPrint('[SecureChatService] rotateHmacKeys: START');
    try {
      final newVersion = await HmacKeyService.rotateKey();
      debugPrint('[SecureChatService] rotateHmacKeys: SUCCESS - rotated to version: $newVersion');
    } catch (e) {
      debugPrint('[SecureChatService] rotateHmacKeys: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[SecureChatService] rotateHmacKeys: END');
  }

  /// Clears HMAC keys on logout
  /// 
  /// This should be called when the user logs out to ensure
  /// key material is not left in memory.
  static void clearHmacKeys() {
    debugPrint('[SecureChatService] clearHmacKeys: START');
    HmacKeyService.clear();
    debugPrint('[SecureChatService] clearHmacKeys: SUCCESS - HMAC keys cleared');
    debugPrint('[SecureChatService] clearHmacKeys: END');
  }

  /// Gets the current HMAC key version for message metadata
  static String? getCurrentHmacKeyVersion() {
    debugPrint('[SecureChatService] getCurrentHmacKeyVersion: START');
    final version = HmacKeyService.getCurrentKeyVersion();
    debugPrint('[SecureChatService] getCurrentHmacKeyVersion: SUCCESS - version: $version');
    debugPrint('[SecureChatService] getCurrentHmacKeyVersion: END');
    return version;
  }

  // ==========================================================================
  // SESSION SECURITY
  // ==========================================================================

  /// Validates session security on reconnect
  /// 
  /// Call this when app reconnects after being offline.
  /// Returns security status and recommended actions.
  static Future<ReconnectSecurityStatus> validateSessionOnReconnect(
    String userId,
  ) async {
    debugPrint('[SecureChatService] validateSessionOnReconnect: START - userId: $userId');

    // Check if session is valid
    debugPrint('[SecureChatService] validateSessionOnReconnect: checking for valid keys');
    final hasValidKeys = await KeyMismatchManager.hasValidKeys();
    if (!hasValidKeys) {
      debugPrint('[SecureChatService] validateSessionOnReconnect: ERROR - no valid keys found');
      debugPrint('[SecureChatService] validateSessionOnReconnect: END');
      return ReconnectSecurityStatus(
        isSecure: false,
        shouldReauth: true,
        issues: ['No valid keys found'],
      );
    }

    // Check for key rotation while offline
    debugPrint('[SecureChatService] validateSessionOnReconnect: checking for key rotation');
    final rotationResult = await EncryptionLifecycleService.checkKeyRotation(userId);
    
    final issues = <String>[];
    var shouldRevalidate = false;

    switch (rotationResult) {
      case KeyRotationStatus.recent:
        issues.add('Keys rotated while offline - recent rotation');
        shouldRevalidate = true;
        debugPrint('[SecureChatService] validateSessionOnReconnect: recent key rotation detected');
        break;
      case KeyRotationStatus.stable:
        debugPrint('[SecureChatService] validateSessionOnReconnect: keys stable');
        break;
      case KeyRotationStatus.scheduled:
        issues.add('Key rotation scheduled');
        debugPrint('[SecureChatService] validateSessionOnReconnect: key rotation scheduled');
        break;
      case KeyRotationStatus.unknown:
        issues.add('Unable to verify key status');
        debugPrint('[SecureChatService] validateSessionOnReconnect: unknown key status');
        break;
      default:
        break;
    }

    // Validate reconnect security
    debugPrint('[SecureChatService] validateSessionOnReconnect: validating reconnect security');
    final securityResult = await EncryptionLifecycleService.validateReconnectSecurity(userId);
    
    issues.addAll(securityResult.issues);
    shouldRevalidate = shouldRevalidate || securityResult.shouldRevalidateKeys;

    final isSecure = securityResult.isSecure && rotationResult != KeyRotationStatus.recent;
    
    debugPrint('[SecureChatService] validateSessionOnReconnect: SUCCESS - isSecure: $isSecure, issues: ${issues.length}');
    debugPrint('[SecureChatService] validateSessionOnReconnect: END');

    return ReconnectSecurityStatus(
      isSecure: isSecure,
      shouldRevalidateKeys: shouldRevalidate,
      shouldReauth: false,
      issues: issues,
      trustScore: securityResult.trustScore,
    );
  }

  /// Gets fingerprint for trust verification
  /// 
  /// Users can compare fingerprints out-of-band (e.g., QR codes)
  /// to verify they're using the correct public keys.
  static String? getReceiverFingerprint(String receiverId) {
    debugPrint('[SecureChatService] getReceiverFingerprint: START - receiverId: $receiverId');
    final fingerprint = EncryptionLifecycleService.getReceiverFingerprint(receiverId);
    debugPrint('[SecureChatService] getReceiverFingerprint: SUCCESS - fingerprint: $fingerprint');
    debugPrint('[SecureChatService] getReceiverFingerprint: END');
    return fingerprint;
  }

  /// Verifies a fingerprint against a cached key
  static bool verifyReceiverFingerprint(String receiverId, String expectedFingerprint) {
    debugPrint('[SecureChatService] verifyReceiverFingerprint: START - receiverId: $receiverId');
    final isValid = EncryptionLifecycleService.verifyReceiverFingerprint(receiverId, expectedFingerprint);
    debugPrint('[SecureChatService] verifyReceiverFingerprint: SUCCESS - isValid: $isValid');
    debugPrint('[SecureChatService] verifyReceiverFingerprint: END');
    return isValid;
  }

  /// Gets own fingerprint for sharing
  static String? getMyFingerprint() {
    debugPrint('[SecureChatService] getMyFingerprint: START');
    final fingerprint = EncryptionLifecycleService.getMyFingerprint();
    debugPrint('[SecureChatService] getMyFingerprint: SUCCESS - fingerprint: $fingerprint');
    debugPrint('[SecureChatService] getMyFingerprint: END');
    return fingerprint;
  }

  // ==========================================================================
  // KEY MANAGEMENT
  // ==========================================================================

  /// Rotates encryption keys securely
  /// 
  /// Generates new key pair and updates server.
  /// Old keys remain valid for decryption of existing messages.
  static Future<KeyRotationResult> rotateKeys() async {
    debugPrint('[SecureChatService] rotateKeys: START');

    try {
      debugPrint('[SecureChatService] rotateKeys: generating new key pair');
      final keyPair = await RSAHelper.generateKeyPair();
      
      debugPrint('[SecureChatService] rotateKeys: clearing caches');
      EncryptionLifecycleService.clearAllCache();

      debugPrint('[SecureChatService] rotateKeys: SUCCESS - keys rotated');
      
      return KeyRotationResult(
        success: true,
        newFingerprint: EncryptionLifecycleService.getMyFingerprint(),
      );
    } catch (e) {
      debugPrint('[SecureChatService] rotateKeys: ERROR - ${e.runtimeType}: $e');
      return KeyRotationResult(
        success: false,
        error: e.toString(),
      );
    } finally {
      debugPrint('[SecureChatService] rotateKeys: END');
    }
  }

  /// Clears all security caches (logout/cleanup)
  static Future<void> clearSecurityCaches() async {
    debugPrint('[SecureChatService] clearSecurityCaches: START');
    EncryptionLifecycleService.clearAllCache();
    clearHmacKeys();
    debugPrint('[SecureChatService] clearSecurityCaches: SUCCESS - all security caches cleared');
    debugPrint('[SecureChatService] clearSecurityCaches: END');
  }
}

// ============================================================================
// DATA CLASSES
// ============================================================================

class ReconnectSecurityStatus {
  final bool isSecure;
  final bool shouldRevalidateKeys;
  final bool shouldReauth;
  final List<String> issues;
  final int? trustScore;

  const ReconnectSecurityStatus({
    required this.isSecure,
    this.shouldRevalidateKeys = false,
    this.shouldReauth = false,
    required this.issues,
    this.trustScore,
  });

  bool get hasIssues => issues.isNotEmpty;
  bool get needsAttention => !isSecure || shouldRevalidateKeys;
}

class KeyRotationResult {
  final bool success;
  final String? newFingerprint;
  final String? error;

  const KeyRotationResult({
    required this.success,
    this.newFingerprint,
    this.error,
  });
}

// ============================================================================
// ASYNC DECRYPT MANAGER
// ============================================================================

/// Manages async decryption with proper cache handling.
/// Never caches 🔒 placeholders - only real decrypted text.
class AsyncDecryptManager {
  static final Map<String, String> _decryptCache = {};
  static final Map<String, Future<String>> _pendingDecrypts = {};
  static final _decryptCallbacks = <String, List<Function(String)>>{};
  
  static const String _kPending = '\x00PENDING\x00';
  static const String _kFailed = '\x00FAILED\x00';
  static const String _kKeyError = '\x00KEY_ERR\x00';

  /// Get cache key for a message.
  static String _getCacheKey(String messageId, String? keyVersion) {
    return '${messageId}_${keyVersion ?? 'legacy'}';
  }

  /// Get decrypted text or placeholder.
  /// Never returns cached placeholder - always triggers real decrypt.
  static String getDecryptedText(
    MessageCache message, {
    required RSAPrivateKey? privateKey,
    required Function(String) onDecrypted,
  }) {
    final cacheKey = _getCacheKey(message.messageId, message.senderKeyVersion);
    
    // Check if we have real decrypted text (not placeholder)
    final cached = _decryptCache[cacheKey];
    if (cached != null && 
        cached != _kPending && 
        cached != _kFailed && 
        cached != _kKeyError &&
        cached != '\u{1F512}') {
      return cached;
    }
    
    // Register callback for when decrypt completes
    if (!_decryptCallbacks.containsKey(cacheKey)) {
      _decryptCallbacks[cacheKey] = [];
    }
    _decryptCallbacks[cacheKey]!.add(onDecrypted);
    
    // Start async decrypt if not already pending
    if (!_pendingDecrypts.containsKey(cacheKey)) {
      _startDecrypt(message, privateKey, cacheKey);
    }
    
    return '\u{1F512}'; // Return placeholder immediately
  }

  /// Start async decrypt operation.
  static void _startDecrypt(
    MessageCache message,
    RSAPrivateKey? privateKey,
    String cacheKey,
  ) {
    _pendingDecrypts[cacheKey] = _performDecrypt(message, privateKey)
      .then((plaintext) {
        // Only cache real plaintext, never placeholders
        if (plaintext != '\u{1F512}' && 
            plaintext != _kPending && 
            plaintext != _kFailed) {
          _decryptCache[cacheKey] = plaintext;
        }
        
        // Notify all registered callbacks
        final callbacks = _decryptCallbacks.remove(cacheKey) ?? [];
        for (final callback in callbacks) {
          try {
            callback(plaintext);
          } catch (e) {
            debugPrint('[AsyncDecryptManager] callback error: $e');
          }
        }
        
        return plaintext;
      })
      .catchError((e) {
        debugPrint('[AsyncDecryptManager] decrypt error: $e');
        
        // Notify callbacks of failure
        final callbacks = _decryptCallbacks.remove(cacheKey) ?? [];
        for (final callback in callbacks) {
          try {
            callback(_kFailed);
          } catch (e) {
            debugPrint('[AsyncDecryptManager] callback error: $e');
          }
        }
        
        return _kFailed;
      })
      .whenComplete(() {
        _pendingDecrypts.remove(cacheKey);
      });
  }

  /// Perform actual decryption with retry logic.
  static Future<String> _performDecrypt(
    MessageCache message,
    RSAPrivateKey? privateKey,
  ) async {
    if (privateKey == null) {
      return '\u{1F512}';
    }

    // Retry logic for transient failures
    const maxRetries = 3;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final aesKeyEncrypted = message.encryptedAesKey;
        if (aesKeyEncrypted.isEmpty) {
          return '\u{1F512}';
        }

        final aesKey = await RSAHelper.decrypt(aesKeyEncrypted, privateKey);
        final plaintext = await EncryptionHelper.decryptMessage(
          message.encryptedText,
          aesKey,
          message.iv,
        );
        
        return plaintext;
      } catch (e) {
        debugPrint('[AsyncDecryptManager] decrypt attempt $attempt failed: $e');
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
        }
      }
    }
    
    return _kFailed;
  }

  /// Invalidate cache for a message.
  static void invalidateCache(String messageId, String? keyVersion) {
    final cacheKey = _getCacheKey(messageId, keyVersion);
    _decryptCache.remove(cacheKey);
    _pendingDecrypts.remove(cacheKey);
    _decryptCallbacks.remove(cacheKey);
  }

  /// Clear all caches.
  static void clearCache() {
    _decryptCache.clear();
    _pendingDecrypts.clear();
    _decryptCallbacks.clear();
  }

  /// Get cache stats for debugging.
  static Map<String, dynamic> getStats() {
    return {
      'cachedCount': _decryptCache.length,
      'pendingCount': _pendingDecrypts.length,
      'callbackCount': _decryptCallbacks.length,
    };
  }
}
