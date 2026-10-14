import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';

import '../utils/rsa_helper.dart';
import 'device_service.dart';
import 'session_lifecycle_manager.dart';

/// Validation result for session integrity checks
enum ValidationResult {
  /// Validation passed
  valid,

  /// Session ID mismatch (possible replay)
  sessionMismatch,

  /// Sequence number error (replay or out of order)
  sequenceError,

  /// Timestamp too old (stale message)
  staleTimestamp,

  /// Device not trusted
  deviceUntrusted,

  /// Signature verification failed
  signatureInvalid,

  /// Unknown error
  unknownError,
}

/// Message validation metadata
class ValidationMetadata {
  final String messageId;
  final String sessionId;
  final int sequenceNumber;
  final DateTime timestamp;
  final String deviceId;
  final Uint8List? signature;

  ValidationMetadata({
    required this.messageId,
    required this.sessionId,
    required this.sequenceNumber,
    required this.timestamp,
    required this.deviceId,
    this.signature,
  });

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'sessionId': sessionId,
      'sequenceNumber': sequenceNumber,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'deviceId': deviceId,
      'signature': signature != null ? base64Encode(signature!) : null,
    };
  }

  static ValidationMetadata fromMap(Map<String, dynamic> map) {
    return ValidationMetadata(
      messageId: map['messageId'] as String,
      sessionId: map['sessionId'] as String,
      sequenceNumber: map['sequenceNumber'] as int,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      deviceId: map['deviceId'] as String,
      signature: map['signature'] != null
          ? base64Decode(map['signature'] as String)
          : null,
    );
  }
}

/// Replay protection entry
class ReplayEntry {
  final String messageId;
  final DateTime receivedAt;
  final ValidationResult result;

  ReplayEntry({
    required this.messageId,
    required this.receivedAt,
    required this.result,
  });
}

/// Service for session validation, replay protection, and message integrity.
///
/// CRITICAL SECURITY PRINCIPLES:
/// 1. All messages must be validated before processing
/// 2. Sequence numbers prevent replay and reordering attacks
/// 3. Timestamps prevent stale message replay
/// 4. Device trust is verified for every message
/// 5. Message signatures are verified when available
class SessionValidationService {
  static final SessionValidationService _instance = SessionValidationService._internal();
  factory SessionValidationService() => _instance;
  SessionValidationService._internal();

  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();

  // Replay protection cache
  static final Map<String, ReplayEntry> _replayCache = {};
  static final _validationController = StreamController<ValidationResult>.broadcast();

  // Configuration
  static const Duration _maxMessageAge = Duration(minutes: 5);
  static const Duration _replayCacheTTL = Duration(minutes: 10);
  static const int _maxSequenceGap = 100;
  static const int _maxCacheSize = 1000;

  // Sequence tracking per device
  static final Map<String, int> _lastSequenceNumbers = {};

  static void _dbg(String message) {
    assert(() {
      debugPrint('[VALIDATE] $message');
      return true;
    }());
  }

  /// Stream of validation results
  static Stream<ValidationResult> get validationStream => _validationController.stream;

  /// Validate a message before processing.
  ///
  /// Returns ValidationResult.valid if message is safe to process.
  /// All other results indicate the message should be rejected.
  static Future<ValidationResult> validateMessage({
    required User user,
    required ValidationMetadata metadata,
    bool requireSignature = false,
  }) async {
    _dbg('validateMessage: START - messageId: ${metadata.messageId}');

    try {
      // 1. Check replay cache
      final replayCheck = await _checkReplayCache(metadata.messageId);
      if (replayCheck != null) {
        _dbg('validateMessage: REPLAY DETECTED - message already seen');
        return replayCheck;
      }

      // 2. Validate device is trusted
      final deviceTrusted = await _validateDeviceTrust(user, metadata.deviceId);
      if (!deviceTrusted) {
        _dbg('validateMessage: device untrusted - ${metadata.deviceId}');
        _addToReplayCache(metadata.messageId, ValidationResult.deviceUntrusted);
        return ValidationResult.deviceUntrusted;
      }

      // 3. Validate session
      final sessionValid = await _validateSession(user, metadata.sessionId);
      if (!sessionValid) {
        _dbg('validateMessage: session invalid - ${metadata.sessionId}');
        _addToReplayCache(metadata.messageId, ValidationResult.sessionMismatch);
        return ValidationResult.sessionMismatch;
      }

      // 4. Validate timestamp (prevent stale messages)
      final timestampValid = _validateTimestamp(metadata.timestamp);
      if (!timestampValid) {
        _dbg('validateMessage: timestamp stale - ${metadata.timestamp}');
        _addToReplayCache(metadata.messageId, ValidationResult.staleTimestamp);
        return ValidationResult.staleTimestamp;
      }

      // 5. Validate sequence number
      final sequenceValid = _validateSequenceNumber(metadata.deviceId, metadata.sequenceNumber);
      if (!sequenceValid) {
        _dbg('validateMessage: sequence error - ${metadata.sequenceNumber}');
        _addToReplayCache(metadata.messageId, ValidationResult.sequenceError);
        return ValidationResult.sequenceError;
      }

      // 6. Validate signature if present or required
      if (requireSignature || metadata.signature != null) {
        final signatureValid = await _validateSignature(user, metadata);
        if (!signatureValid) {
          _dbg('validateMessage: signature invalid');
          _addToReplayCache(metadata.messageId, ValidationResult.signatureInvalid);
          return ValidationResult.signatureInvalid;
        }
      }

      // Message is valid
      _dbg('validateMessage: VALID');
      _addToReplayCache(metadata.messageId, ValidationResult.valid);
      _validationController.add(ValidationResult.valid);
      return ValidationResult.valid;
    } catch (e) {
      _dbg('validateMessage: ERROR - $e');
      _validationController.add(ValidationResult.unknownError);
      return ValidationResult.unknownError;
    }
  }

  /// Generate validation metadata for outgoing messages
  static Future<ValidationMetadata> generateMetadata({
    required User user,
    required String messageId,
    Uint8List? signature,
  }) async {
    _dbg('generateMetadata: START - messageId: $messageId');

    final session = SessionLifecycleManager.currentSession;
    final deviceId = await DeviceService.getDeviceId();

    // Get next sequence number for this device
    final sequenceNumber = _getNextSequenceNumber(deviceId);

    final metadata = ValidationMetadata(
      messageId: messageId,
      sessionId: session?.sessionId ?? 'unknown',
      sequenceNumber: sequenceNumber,
      timestamp: DateTime.now(),
      deviceId: deviceId,
      signature: signature,
    );

    _dbg('generateMetadata: sequence=$sequenceNumber, session=${session?.sessionId ?? 'unknown'}');
    return metadata;
  }

  /// Record a processed message for replay protection
  static void recordProcessedMessage({
    required String messageId,
    required ValidationResult result,
  }) {
    _addToReplayCache(messageId, result);
  }

  /// Check if a message has been processed (replay check)
  static bool isProcessed(String messageId) {
    _cleanupReplayCache();
    return _replayCache.containsKey(messageId);
  }

  /// Get validation statistics
  static Map<String, int> getValidationStats() {
    final stats = <String, int>{};
    for (final entry in _replayCache.values) {
      final key = entry.result.name;
      stats[key] = (stats[key] ?? 0) + 1;
    }
    return stats;
  }

  /// Clear validation cache (e.g., on logout)
  static void clearCache() {
    _dbg('clearCache: clearing all validation caches');
    _replayCache.clear();
    _lastSequenceNumbers.clear();
  }

  /// Validate session integrity
  ///
  /// Checks that the session exists and hasn't been tampered with
  static Future<bool> validateSessionIntegrity(User user) async {
    _dbg('validateSessionIntegrity: START');

    try {
      final currentSession = SessionLifecycleManager.currentSession;
      if (currentSession == null) {
        _dbg('validateSessionIntegrity: no current session');
        return false;
      }

      // Fetch session from Firestore
      final doc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .doc(currentSession.deviceId)
          .get();

      if (!doc.exists) {
        _dbg('validateSessionIntegrity: session not found in Firestore');
        return false;
      }

      final data = doc.data()!;
      final remoteSessionId = data['sessionId'] as String?;
      final remoteSequence = data['sequenceNumber'] as int? ?? 0;

      // Verify session ID matches
      if (remoteSessionId != currentSession.sessionId) {
        _dbg('validateSessionIntegrity: session ID mismatch');
        return false;
      }

      // Verify sequence number hasn't gone backwards
      if (remoteSequence > currentSession.sequenceNumber) {
        _dbg('validateSessionIntegrity: sequence regression detected');
        return false;
      }

      _dbg('validateSessionIntegrity: VALID');
      return true;
    } catch (e) {
      _dbg('validateSessionIntegrity: ERROR - $e');
      return false;
    }
  }

  /// Get the current sequence number for a device
  static int getCurrentSequenceNumber(String deviceId) {
    return _lastSequenceNumbers[deviceId] ?? 0;
  }

  /// Increment sequence number for outgoing messages
  static int incrementSequenceNumber(String deviceId) {
    final current = _lastSequenceNumbers[deviceId] ?? 0;
    final next = current + 1;
    _lastSequenceNumbers[deviceId] = next;
    return next;
  }

  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================

  static Future<ValidationResult?> _checkReplayCache(String messageId) async {
    _cleanupReplayCache();

    final entry = _replayCache[messageId];
    if (entry != null) {
      return entry.result;
    }

    return null;
  }

  static void _addToReplayCache(String messageId, ValidationResult result) {
    // Enforce max cache size
    if (_replayCache.length >= _maxCacheSize) {
      _cleanupReplayCache(force: true);
    }

    _replayCache[messageId] = ReplayEntry(
      messageId: messageId,
      receivedAt: DateTime.now(),
      result: result,
    );

    _dbg('replay cache: added $messageId with result ${result.name}');
  }

  static void _cleanupReplayCache({bool force = false}) {
    final now = DateTime.now();
    final cutoff = now.subtract(_replayCacheTTL);

    // Remove expired entries
    _replayCache.removeWhere((key, entry) {
      return entry.receivedAt.isBefore(cutoff);
    });

    // If still too large, remove oldest entries
    if (force && _replayCache.length >= _maxCacheSize) {
      final sorted = _replayCache.entries.toList()
        ..sort((a, b) => a.value.receivedAt.compareTo(b.value.receivedAt));

      final toRemove = sorted.length - (_maxCacheSize ~/ 2);
      for (var i = 0; i < toRemove; i++) {
        _replayCache.remove(sorted[i].key);
      }
    }
  }

  static Future<bool> _validateDeviceTrust(User user, String deviceId) async {
    try {
      // Check if it's the current device
      final currentDeviceId = await DeviceService.getDeviceId();
      if (deviceId == currentDeviceId) {
        // Trust is handled by DeviceTrustService
        return true; // Local validation
      }

      // Check Firestore
      final doc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .get();

      if (!doc.exists) return false;

      final data = doc.data()!;
      return (data['trusted'] as bool? ?? false) &&
             !(data['revoked'] as bool? ?? false);
    } catch (e) {
      _dbg('_validateDeviceTrust: ERROR - $e');
      return false;
    }
  }

  static Future<bool> _validateSession(User user, String sessionId) async {
    try {
      final currentSession = SessionLifecycleManager.currentSession;
      if (currentSession == null) return false;

      // Check if session ID matches or is from a synced session
      if (sessionId == currentSession.sessionId) return true;

      // Check if it's a valid synced session
      final doc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .where('sessionId', isEqualTo: sessionId)
          .limit(1)
          .get();

      return doc.docs.isNotEmpty;
    } catch (e) {
      _dbg('_validateSession: ERROR - $e');
      return false;
    }
  }

  static bool _validateTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final age = now.difference(timestamp);

    // Message too old
    if (age > _maxMessageAge) {
      _dbg('_validateTimestamp: message too old (${age.inMinutes}m)');
      return false;
    }

    // Message from future (clock skew)
    if (timestamp.isAfter(now.add(const Duration(minutes: 1)))) {
      _dbg('_validateTimestamp: message from future');
      return false;
    }

    return true;
  }

  static bool _validateSequenceNumber(String deviceId, int sequenceNumber) {
    final lastSequence = _lastSequenceNumbers[deviceId] ?? 0;

    // Must be greater than last seen
    if (sequenceNumber <= lastSequence) {
      _dbg('_validateSequenceNumber: sequence regression (got $sequenceNumber, last was $lastSequence)');
      return false;
    }

    // Gap too large (possible attack or severe message loss)
    if (sequenceNumber - lastSequence > _maxSequenceGap) {
      _dbg('_validateSequenceNumber: sequence gap too large (${sequenceNumber - lastSequence})');
      return false;
    }

    // Update last seen
    _lastSequenceNumbers[deviceId] = sequenceNumber;
    return true;
  }

  static int _getNextSequenceNumber(String deviceId) {
    final current = _lastSequenceNumbers[deviceId] ?? 0;
    final next = current + 1;
    _lastSequenceNumbers[deviceId] = next;
    return next;
  }

  static Future<bool> _validateSignature(
    User user,
    ValidationMetadata metadata,
  ) async {
    _dbg('_validateSignature: START - deviceId=${metadata.deviceId}');
    
    try {
      // Step 1: Retrieve device's public key from Firestore
      final deviceDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(metadata.deviceId)
          .get();
      
      if (!deviceDoc.exists) {
        _dbg('_validateSignature: device key missing - treating as untrusted');
        // Return false (not throw) when device key is missing - treat as untrusted
        return false;
      }
      
      final deviceData = deviceDoc.data();
      if (deviceData == null || deviceData['publicKey'] == null) {
        _dbg('_validateSignature: publicKey field missing in device document');
        return false;
      }
      
      // Parse the public key from the stored format
      final publicKeyData = deviceData['publicKey'] as Map<String, dynamic>;
      final publicKey = RSAPublicKey(
        BigInt.parse(publicKeyData['n'] as String),
        BigInt.parse(publicKeyData['e'] as String),
      );
      
      _dbg('_validateSignature: retrieved public key for device ${metadata.deviceId}');
      
      // Step 2: Verify signature using RSAHelper.verifySignature
      // Construct payload from metadata (excluding the signature itself)
      final payloadMap = {
        'messageId': metadata.messageId,
        'sessionId': metadata.sessionId,
        'sequenceNumber': metadata.sequenceNumber,
        'timestamp': metadata.timestamp.millisecondsSinceEpoch,
        'deviceId': metadata.deviceId,
      };
      final payload = base64Encode(utf8.encode(jsonEncode(payloadMap)));
      final signature = base64Encode(metadata.signature!);
      
      final isValid = RSAHelper.verifySignature(payload, signature, publicKey);
      
      if (isValid) {
        _dbg('_validateSignature: signature VALID');
      } else {
        _dbg('_validateSignature: signature INVALID');
      }
      
      // Step 3: Return true only when signature is valid
      return isValid;
      
    } catch (e) {
      _dbg('_validateSignature: ERROR - ${e.runtimeType}: $e');
      // Return false on any error - don't throw
      return false;
    }
  }
}
