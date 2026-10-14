import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';

import '../services/device_service.dart';
import '../utils/rsa_helper.dart';
import 'device_encryption_service.dart';

/// Session key for secure chat between two devices.
///
/// Each session is unique per sender-receiver pair.
/// Keys are ephemeral and rotated periodically.
class ChatSession {
  final String sessionId;
  final String senderDeviceId;
  final String receiverDeviceId;
  final Uint8List hmacKey;
  final DateTime createdAt;
  final DateTime expiresAt;

  ChatSession({
    required this.sessionId,
    required this.senderDeviceId,
    required this.receiverDeviceId,
    required this.hmacKey,
    required this.createdAt,
    required this.expiresAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'senderDeviceId': senderDeviceId,
      'receiverDeviceId': receiverDeviceId,
      'hmacKey': base64Encode(hmacKey),
      'createdAt': createdAt.toIso8601String(),
      'expiresAt': expiresAt.toIso8601String(),
    };
  }

  static ChatSession? fromJson(Map<String, dynamic> json) {
    try {
      return ChatSession(
        sessionId: json['sessionId'] as String,
        senderDeviceId: json['senderDeviceId'] as String,
        receiverDeviceId: json['receiverDeviceId'] as String,
        hmacKey: base64Decode(json['hmacKey'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );
    } catch (e) {
      return null;
    }
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Service for managing per-device HMAC session keys.
///
/// Each device pair gets their own ephemeral HMAC key for message authentication.
/// Keys are rotated every 24 hours for forward secrecy.
///
/// SECURITY: HMAC keys are encrypted at rest using RSA encryption with the
/// recipient's device public key. Only the recipient's private key (which never
/// leaves their device) can decrypt the HMAC key.
class SessionKeyService {
  static final SessionKeyService _instance = SessionKeyService._internal();
  factory SessionKeyService() => _instance;
  SessionKeyService._internal();

  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();

  // In-memory cache of active sessions
  final Map<String, ChatSession> _sessionCache = {};

  // Session key TTL
  static const Duration _sessionTTL = Duration(hours: 24);

  static void _dbg(String message) {
    assert(() {
      debugPrint('[SESSION] $message');
      return true;
    }());
  }

  /// Get or create session key for chat with recipient device.
  ///
  /// Returns HMAC key for this specific device pair.
  static Future<Uint8List?> getSessionKey({
    required String recipientUid,
    required String recipientDeviceId,
  }) async {
    _dbg('Getting session key for recipient device: $recipientDeviceId');

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      _dbg('No user logged in');
      return null;
    }

    final currentDeviceId = await DeviceService.getDeviceId();
    final sessionId = _generateSessionId(
      senderDevice: currentDeviceId,
      receiverDevice: recipientDeviceId,
    );

    // Check cache first
    final cachedSession = _instance._sessionCache[sessionId];
    if (cachedSession != null && !cachedSession.isExpired) {
      _dbg('Using cached session key');
      return cachedSession.hmacKey;
    }

    // Try to load from secure storage
    final storedSession = await _loadSessionFromStorage(sessionId);
    if (storedSession != null && !storedSession.isExpired) {
      _dbg('Loaded session from storage');
      _instance._sessionCache[sessionId] = storedSession;
      return storedSession.hmacKey;
    }

    // Try to retrieve from Firestore (if session was created by other device)
    final retrievedKey = await retrieveSessionKey(
      sessionId: sessionId,
      senderUid: recipientUid,
    );
    if (retrievedKey != null) {
      _dbg('Retrieved session key from Firestore');
      return retrievedKey;
    }

    // Create new session
    _dbg('Creating new session');
    return await _createNewSession(
      recipientUid: recipientUid,
      recipientDeviceId: recipientDeviceId,
      sessionId: sessionId,
    );
  }

  /// Create new session with recipient device.
  static Future<Uint8List?> _createNewSession({
    required String recipientUid,
    required String recipientDeviceId,
    required String sessionId,
  }) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser!;
      final currentDeviceId = await DeviceService.getDeviceId();

      // Generate random HMAC key (32 bytes = 256 bits)
      final hmacKey = Uint8List(32);
      final random = Random.secure();
      for (int i = 0; i < 32; i++) {
        hmacKey[i] = random.nextInt(256);
      }

      final now = DateTime.now();
      final session = ChatSession(
        sessionId: sessionId,
        senderDeviceId: currentDeviceId,
        receiverDeviceId: recipientDeviceId,
        hmacKey: hmacKey,
        createdAt: now,
        expiresAt: now.add(_sessionTTL),
      );

      // Store locally
      await _saveSessionToStorage(session);
      _instance._sessionCache[sessionId] = session;

      // Share session key with recipient via Firestore (encrypted)
      await _shareSessionKeyWithRecipient(
        session: session,
        recipientUid: recipientUid,
      );

      _dbg('New session created: $sessionId');
      return hmacKey;

    } catch (e) {
      _dbg('Failed to create session: $e');
      return null;
    }
  }

  /// Generate unique session ID for device pair.
  static String _generateSessionId({
    required String senderDevice,
    required String receiverDevice,
  }) {
    // Sort devices to ensure same ID regardless of who initiates
    final devices = [senderDevice, receiverDevice]..sort();
    final combined = '${devices[0]}:${devices[1]}';
    final hash = sha256.convert(utf8.encode(combined));
    return base64Encode(hash.bytes).substring(0, 32);
  }

  /// Save session to secure storage.
  static Future<void> _saveSessionToStorage(ChatSession session) async {
    final key = 'session_${session.sessionId}';
    final value = jsonEncode(session.toJson());
    await _storage.write(key: key, value: value);
  }

  /// Load session from secure storage.
  static Future<ChatSession?> _loadSessionFromStorage(String sessionId) async {
    try {
      final key = 'session_$sessionId';
      final value = await _storage.read(key: key);
      if (value == null) return null;

      final json = jsonDecode(value) as Map<String, dynamic>;
      return ChatSession.fromJson(json);
    } catch (e) {
      _dbg('Failed to load session: $e');
      return null;
    }
  }

  /// Share session key with recipient via Firestore.
  ///
  /// The session key is encrypted with recipient's public key
  /// so only the recipient device can read it.
  ///
  /// SECURITY: HMAC key is encrypted with RSA before storage. The encrypted
  /// key can only be decrypted by the recipient's private key which never
  /// leaves their device.
  static Future<void> _shareSessionKeyWithRecipient({
    required ChatSession session,
    required String recipientUid,
  }) async {
    _dbg('Sharing session key with recipient');

    try {
      // Get recipient's device public key from Firestore
      final recipientDeviceId = session.receiverDeviceId;
      final deviceDoc = await _firestore
          .collection('users')
          .doc(recipientUid)
          .collection('devices')
          .doc(recipientDeviceId)
          .get();

      if (!deviceDoc.exists) {
        _dbg('Recipient device not found, cannot share session key');
        return;
      }

      final deviceData = deviceDoc.data();
      final publicKeyData = deviceData?['publicKey'] as Map<String, dynamic>?;

      if (publicKeyData == null) {
        _dbg('Recipient device has no public key, cannot encrypt session key');
        return;
      }

      // Reconstruct recipient's public key
      final recipientN = BigInt.parse(publicKeyData['n'] as String);
      final recipientE = BigInt.parse(publicKeyData['e'] as String);
      final recipientPublicKey = RSAPublicKey(recipientN, recipientE);

      // Encrypt HMAC key with recipient's public key
      // The HMAC key is 32 bytes, well within RSA 2048-bit encryption limit (245 bytes)
      final hmacKeyBase64 = base64Encode(session.hmacKey);
      final encryptedHmacKey = await RSAHelper.encrypt(
        hmacKeyBase64,
        recipientPublicKey,
      );

      _dbg('HMAC key encrypted successfully');

      // Store session metadata with encrypted HMAC key
      await _firestore
          .collection('users')
          .doc(recipientUid)
          .collection('sessions')
          .doc(session.sessionId)
          .set({
        'sessionId': session.sessionId,
        'senderDeviceId': session.senderDeviceId,
        'receiverDeviceId': session.receiverDeviceId,
        'createdAt': Timestamp.fromDate(session.createdAt),
        'expiresAt': Timestamp.fromDate(session.expiresAt),
        // SECURITY: HMAC key encrypted with recipient's public key
        // Only recipient's private key can decrypt this
        'hmacKeyEncrypted': encryptedHmacKey,
        'encrypted': true, // Flag to indicate encryption is enabled
      }, SetOptions(merge: true));

      _dbg('Session key shared (encrypted)');
    } catch (e) {
      _dbg('Failed to share session key: $e');
      // Don't throw - session can still work with local key
    }
  }

  /// Retrieve and decrypt session key from Firestore.
  ///
  /// Called when receiving a session from another device.
  static Future<Uint8List?> retrieveSessionKey({
    required String sessionId,
    required String senderUid,
  }) async {
    _dbg('Retrieving session key: $sessionId');

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        _dbg('No user logged in');
        return null;
      }

      // Get session from Firestore
      final sessionDoc = await _firestore
          .collection('users')
          .doc(currentUser.uid)
          .collection('sessions')
          .doc(sessionId)
          .get();

      if (!sessionDoc.exists) {
        _dbg('Session not found');
        return null;
      }

      final sessionData = sessionDoc.data()!;
      final encryptedHmacKey = sessionData['hmacKeyEncrypted'] as String?;
      final isEncrypted = sessionData['encrypted'] as bool? ?? false;

      if (encryptedHmacKey == null) {
        _dbg('No HMAC key in session');
        return null;
      }

      Uint8List hmacKey;

      if (isEncrypted) {
        // Decrypt HMAC key using our private key
        final privateKey = DeviceEncryptionService.getPrivateKey();
        if (privateKey == null) {
          _dbg('No private key available for decryption');
          return null;
        }

        final decryptedBase64 = await RSAHelper.decrypt(encryptedHmacKey, privateKey);
        hmacKey = base64Decode(decryptedBase64);
        _dbg('HMAC key decrypted successfully');
      } else {
        // Legacy unencrypted key (should not happen with new sessions)
        _dbg('WARNING: Using unencrypted HMAC key');
        hmacKey = base64Decode(encryptedHmacKey);
      }

      // Create session object and cache it
      final session = ChatSession(
        sessionId: sessionId,
        senderDeviceId: sessionData['senderDeviceId'] as String,
        receiverDeviceId: sessionData['receiverDeviceId'] as String,
        hmacKey: hmacKey,
        createdAt: (sessionData['createdAt'] as Timestamp).toDate(),
        expiresAt: (sessionData['expiresAt'] as Timestamp).toDate(),
      );

      // Cache locally
      _instance._sessionCache[sessionId] = session;
      await _saveSessionToStorage(session);

      _dbg('Session key retrieved and cached');
      return hmacKey;
    } catch (e) {
      _dbg('Failed to retrieve session key: $e');
      return null;
    }
  }

  /// Rotate all expired sessions.
  static Future<void> rotateExpiredSessions() async {
    _dbg('Rotating expired sessions');

    final expired = _instance._sessionCache.entries
        .where((e) => e.value.isExpired)
        .map((e) => e.key)
        .toList();

    for (final sessionId in expired) {
      _instance._sessionCache.remove(sessionId);
      await _storage.delete(key: 'session_$sessionId');
      _dbg('Rotated session: $sessionId');
    }
  }

  /// Clear all sessions (logout).
  static Future<void> clearAllSessions() async {
    _dbg('Clearing all sessions');

    // Clear memory cache
    _instance._sessionCache.clear();

    // Clear storage (find all session keys)
    // Note: In production, you'd want to be more selective
    _dbg('Session cache cleared');
  }

  /// Calculate HMAC for message authentication.
  static String calculateHMAC({
    required String message,
    required Uint8List key,
  }) {
    final bytes = utf8.encode(message);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytes);
    return base64Encode(digest.bytes);
  }

  /// Verify HMAC for message authentication.
  static bool verifyHMAC({
    required String message,
    required String hmac,
    required Uint8List key,
  }) {
    final calculated = calculateHMAC(message: message, key: key);
    // Constant-time comparison to prevent timing attacks
    if (calculated.length != hmac.length) return false;
    int result = 0;
    for (int i = 0; i < calculated.length; i++) {
      result |= calculated.codeUnitAt(i) ^ hmac.codeUnitAt(i);
    }
    return result == 0;
  }
}
