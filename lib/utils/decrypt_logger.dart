import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

/// Comprehensive logging utility for decrypt operations
/// 
/// Provides detailed error logging to help diagnose decryption failures
/// without exposing sensitive key material.
class DecryptLogger {
  static const String _tag = '[Decrypt]';
  
  /// Logs detailed decrypt attempt with context
  static void logAttempt({
    required String messageId,
    required String operation, // 'decrypt' or 'decryptOwn'
    required String? keyVersion,
    required bool hasAesKey,
    required bool hasIv,
    required bool hasPrivateKey,
    int? retryCount,
  }) {
    _log(
      '$operation[$messageId]: '
      'keyVersion=$keyVersion, '
      'hasAesKey=$hasAesKey, '
      'hasIv=$hasIv, '
      'hasPrivateKey=$hasPrivateKey'
      '${retryCount != null ? ", retry=$retryCount" : ""}',
    );
  }
  
  /// Logs successful decryption
  static void logSuccess(String messageId, String operation) {
    _log('$operation[$messageId]: SUCCESS');
  }
  
  /// Logs decryption error with detailed context
  static void logError({
    required String messageId,
    required String operation,
    required Object error,
    StackTrace? stackTrace,
    String? aesKeyLength,
    String? ivLength,
    String? ciphertextLength,
    bool isLegacy = false,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('$operation[$messageId]: FAILED');
    buffer.writeln('  errorType: ${error.runtimeType}');
    buffer.writeln('  error: ${_sanitizeError(error.toString())}');
    buffer.writeln('  isLegacy: $isLegacy');
    
    if (aesKeyLength != null) {
      buffer.writeln('  aesKeyLength: $aesKeyLength');
    }
    if (ivLength != null) {
      buffer.writeln('  ivLength: $ivLength');
    }
    if (ciphertextLength != null) {
      buffer.writeln('  ciphertextLength: $ciphertextLength');
    }
    
    _log(buffer.toString(), isError: true);
    
    if (stackTrace != null && kDebugMode) {
      developer.log(
        'StackTrace for $messageId:',
        name: _tag,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  
  /// Logs legacy fallback being used
  static void logLegacyFallback(String messageId, String reason) {
    _log('decrypt[$messageId]: Using LEGACY fallback - $reason');
  }
  
  /// Logs cache operations
  static void logCache({
    required String messageId,
    required String operation, // 'hit', 'miss', 'store', 'invalidate'
    String? keyVersion,
  }) {
    _log('cache[$messageId]: $operation${keyVersion != null ? " (v$keyVersion)" : ""}');
  }
  
  /// Logs key version mismatch
  static void logVersionMismatch({
    required String messageId,
    required String msgVersion,
    required String loadedVersion,
  }) {
    _log(
      'version[$messageId]: MISMATCH - '
      'msg=$msgVersion, loaded=$loadedVersion',
      isError: true,
    );
  }
  
  /// Internal logging method
  static void _log(String message, {bool isError = false}) {
    final fullMessage = '$_tag $message';
    
    if (isError) {
      developer.log(fullMessage, name: _tag, level: 1000); // Level SEVERE
    } else {
      developer.log(fullMessage, name: _tag, level: 800); // Level INFO
    }
    
    // Also print in debug mode for console visibility
    assert(() {
      // ignore: avoid_print
      print(fullMessage);
      return true;
    }());
  }
  
  /// Sanitizes error messages to avoid logging sensitive data
  static String _sanitizeError(String error) {
    // Remove potential key material or PII
    return error
        .replaceAll(RegExp(r'[A-Za-z0-9+/]{100,}'), '[BASE64_DATA]')
        .replaceAll(RegExp(r'\b[0-9a-fA-F]{32,}\b'), '[HEX_DATA]')
        .replaceAll(RegExp(r'modulus=[0-9]+'), 'modulus=[REDACTED]')
        .replaceAll(RegExp(r'exponent=[0-9]+'), 'exponent=[REDACTED]');
  }
}

/// Legacy message detection utility
/// 
/// Helps identify old message formats and route them appropriately.
class LegacyMessageDetector {
  /// Checks if a message is in legacy format (pre-security-hardening)
  static bool isLegacyMessage(Map<String, dynamic> data) {
    // Legacy messages don't have these security fields
    final hasSecurityFields = 
        data.containsKey('_nonce') ||
        data.containsKey('_idempotencyKey') ||
        data.containsKey('_hmac');
    
    // Legacy messages might have different field names
    final hasLegacyFields = 
        data.containsKey('text_plain') ||
        (!data.containsKey('aesKey') && !data.containsKey('aesKeySender'));
    
    // Check keyVersion field
    final keyVersion = data['senderKeyVersion'] as String?;
    final hasExplicitLegacy = keyVersion == 'legacy' || keyVersion == null;
    
    return !hasSecurityFields || hasLegacyFields || hasExplicitLegacy;
  }
  
  /// Gets the appropriate AES key field for a message
  /// Returns the field name to use, or null if not found
  static String? getAesKeyField(Map<String, dynamic> data, {required bool isOwnMessage}) {
    // Try standard fields first
    if (isOwnMessage) {
      // For own messages, try aesKeySender first (new format)
      if (data['aesKeySender'] is String && (data['aesKeySender'] as String).isNotEmpty) {
        return 'aesKeySender';
      }
      // Fallback to aesKey (legacy format where both parties use same key)
      if (data['aesKey'] is String && (data['aesKey'] as String).isNotEmpty) {
        return 'aesKey';
      }
    } else {
      // For received messages, try aesKey first
      if (data['aesKey'] is String && (data['aesKey'] as String).isNotEmpty) {
        return 'aesKey';
      }
      // Fallback to aesKeySender (legacy format)
      if (data['aesKeySender'] is String && (data['aesKeySender'] as String).isNotEmpty) {
        return 'aesKeySender';
      }
    }
    
    return null;
  }
  
  /// Extracts plaintext if message has text_plain field (legacy plaintext storage)
  static String? getPlaintextFallback(Map<String, dynamic> data) {
    // Check for plaintext storage (legacy insecure format)
    final textPlain = data['text_plain'] as String?;
    if (textPlain != null && textPlain.isNotEmpty) {
      return textPlain;
    }
    
    // Check if message was never encrypted (test messages, etc.)
    final text = data['text'] as String?;
    if (text != null && !text.startsWith('U2FsdGVk')) { // Not base64 encrypted
      return text;
    }
    
    return null;
  }
}
