import 'dart:async';

import '../utils/rsa_helper.dart';
import '../utils/encryption.dart';
import 'decrypt_queue_manager.dart';
import 'decrypt_memoization_service.dart';

/// Unified decryption service - SINGLE ENTRY POINT for all decryption operations.
///
/// This service consolidates decryption that was previously scattered across 17+ files.
/// All decryption MUST go through this service to ensure:
/// - Queue management (prevents rebuild storms)
/// - Memoization (prevents duplicate decrypts)
/// - Proper error handling
/// - Timeout handling
///
/// MIGRATION GUIDE:
/// Before (scattered direct calls):
///   final plaintext = await RSAHelper.decrypt(encrypted, privateKey);
///   final message = await EncryptionHelper.decryptMessage(ciphertext, aesKey, iv);
///
/// After (unified through this service):
///   final result = await UnifiedDecryptService.decryptMessage(
///     messageId: messageId,
///     encryptedText: encryptedText,
///     encryptedAesKey: encryptedAesKey,
///     iv: iv,
///     privateKey: privateKey,
///   );
class UnifiedDecryptService {
  // Dependencies
  static final _queueManager = DecryptQueueManager();
  static final _memoizationService = DecryptMemoizationService();

  // Statistics for monitoring
  static int _totalRequests = 0;
  static int _cacheHits = 0;
  static int _queueHits = 0;

  /// Get decryption statistics
  static Map<String, int> get stats => {
    'totalRequests': _totalRequests,
    'cacheHits': _cacheHits,
    'queueHits': _queueHits,
    'memoizationSize': _memoizationService.cacheSize,
    'queueActive': _queueManager.activeCount,
    'queueLength': _queueManager.queueLength,
  };

  // ==========================================================================
  // PRIMARY API - Use these methods for all decryption
  // ==========================================================================

  /// Decrypt a message using RSA (decrypt AES key) + AES (decrypt message).
  ///
  /// This is the primary method for message decryption. It:
  /// 1. Checks memoization cache first
  /// 2. If not cached, queues the decrypt operation
  /// 3. Handles timeouts and errors
  /// 4. Returns a DecryptResult with plaintext or error
  static Future<DecryptResult> decryptMessage({
    required String messageId,
    required String encryptedText,
    required String encryptedAesKey,
    required String iv,
    required dynamic privateKey,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _totalRequests++;

    // Check memoization cache first
    final cached = _memoizationService.getResult(messageId);
    if (cached != null && !cached.isStale) {
      _cacheHits++;
      return cached;
    }

    // Check if already being decrypted (queue deduplication)
    if (_memoizationService.isDecrypting(messageId)) {
      _queueHits++;
      return await _memoizationService.waitForResult(messageId, timeout: timeout);
    }

    // Use memoization service which handles caching and deduplication
    try {
      final plaintext = await _memoizationService.getDecryptedMessage(
        messageId,
        () async {
          // Decrypt AES key with RSA
          final aesKey = await RSAHelper.decrypt(encryptedAesKey, privateKey)
              .timeout(timeout);

          // Decrypt message with AES
          return await EncryptionHelper.decryptMessage(
            encryptedText,
            aesKey,
            iv,
          ).timeout(timeout);
        },
      );

      return DecryptResult.success(plaintext);
    } catch (e) {
      return DecryptResult.failure('Decrypt failed: $e');
    }
  }

  /// Decrypt using only RSA (for key exchange, etc).
  static Future<DecryptResult> decryptRSA({
    required String operationId,
    required String encryptedData,
    required dynamic privateKey,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _totalRequests++;

    // Check memoization
    final cached = _memoizationService.getResult(operationId);
    if (cached != null && !cached.isStale) {
      _cacheHits++;
      return cached;
    }

    // Check if already in progress
    if (_memoizationService.isDecrypting(operationId)) {
      _queueHits++;
      return await _memoizationService.waitForResult(operationId, timeout: timeout);
    }

    try {
      final plaintext = await _memoizationService.getDecryptedMessage(
        operationId,
        () async => await RSAHelper.decrypt(encryptedData, privateKey).timeout(timeout),
      );
      return DecryptResult.success(plaintext);
    } catch (e) {
      return DecryptResult.failure('RSA decrypt failed: $e');
    }
  }

  /// Decrypt using only AES (for bulk data, session keys, etc).
  static Future<DecryptResult> decryptAES({
    required String operationId,
    required String encryptedData,
    required String key,
    required String iv,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _totalRequests++;

    // Check memoization
    final cached = _memoizationService.getResult(operationId);
    if (cached != null && !cached.isStale) {
      _cacheHits++;
      return cached;
    }

    // Check if already in progress
    if (_memoizationService.isDecrypting(operationId)) {
      _queueHits++;
      return await _memoizationService.waitForResult(operationId, timeout: timeout);
    }

    try {
      final plaintext = await _memoizationService.getDecryptedMessage(
        operationId,
        () async => await EncryptionHelper.decryptMessage(
          encryptedData,
          key,
          iv,
        ).timeout(timeout),
      );
      return DecryptResult.success(plaintext);
    } catch (e) {
      return DecryptResult.failure('AES decrypt failed: $e');
    }
  }

  // ==========================================================================
  // CACHE MANAGEMENT
  // ==========================================================================

  /// Check if a message is already cached.
  static bool isCached(String messageId) {
    return _memoizationService.getResult(messageId) != null;
  }

  /// Get cached result (returns null if not cached or stale).
  static DecryptResult? getCached(String messageId) {
    return _memoizationService.getResult(messageId);
  }

  /// Clear a specific cached result.
  static void clearCache(String messageId) {
    _memoizationService.clearResult(messageId);
  }

  /// Clear all cached results.
  static void clearAllCache() {
    _memoizationService.clearAll();
    _resetStats();
  }

  /// Clear cache for a specific room/conversation.
  static void clearRoomCache(String roomId) {
    _memoizationService.clearAll(); // Currently clears all, could be made selective
  }

  // ==========================================================================
  // STREAMS
  // ==========================================================================

  /// Stream of decrypt completion events.
  static Stream<String> get onDecryptComplete => _queueManager.onDecryptComplete;

  /// Listen for decrypt completion (convenience method).
  static StreamSubscription<String> listenToDecrypts(
    void Function(String messageId) onComplete,
  ) {
    return _queueManager.onDecryptComplete.listen(onComplete);
  }

  // ==========================================================================
  // LEGACY SUPPORT - Gradual migration helpers
  // ==========================================================================

  /// Legacy-compatible decrypt that returns String (not DecryptResult).
  /// 
  /// WARNING: This loses error information. Prefer decryptMessage() which
  /// returns DecryptResult with success/error details.
  @Deprecated('Use decryptMessage() which returns DecryptResult with full error info')
  static Future<String> decryptMessageLegacy({
    required String messageId,
    required String encryptedText,
    required String encryptedAesKey,
    required String iv,
    required dynamic privateKey,
    String fallbackText = '🔒',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await decryptMessage(
      messageId: messageId,
      encryptedText: encryptedText,
      encryptedAesKey: encryptedAesKey,
      iv: iv,
      privateKey: privateKey,
      timeout: timeout,
    );
    return result.success ? result.plaintext : fallbackText;
  }

  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================

  static void _resetStats() {
    _totalRequests = 0;
    _cacheHits = 0;
    _queueHits = 0;
  }
}

/// Extension methods for easier migration
extension DecryptResultExtension on DecryptResult {
  /// Get plaintext or fallback if failed.
  String get plaintextOrLock => success ? plaintext : '🔒';

  /// Get plaintext or empty if failed.
  String get plaintextOrEmpty => success ? plaintext : '';

  /// Get plaintext or custom fallback.
  String plaintextOr(String fallback) => success ? plaintext : fallback;
}
