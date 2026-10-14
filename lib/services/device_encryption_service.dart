import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';

import '../utils/rsa_helper.dart';
import 'device_service.dart';
import 'device_trust_service.dart';
import 'device_trust_state_manager.dart';

/// Exception thrown when device trust is required but not granted
class DeviceTrustRequiredException implements Exception {
  final String message;
  
  DeviceTrustRequiredException(this.message);
  
  @override
  String toString() => 'DeviceTrustRequiredException: $message';
}

/// Per-device encryption key manager.
///
/// CRITICAL ARCHITECTURE CHANGE:
/// - Each device has its OWN RSA keypair
/// - Private key NEVER leaves the device
/// - Public key uploaded to: users/{uid}/devices/{deviceId}/publicKey
/// - NO account-level key overwrite
/// - Messages are encrypted for EACH device separately
///
/// This eliminates key mismatch errors between devices.
class DeviceEncryptionService {
  static final DeviceEncryptionService _instance = DeviceEncryptionService._internal();
  factory DeviceEncryptionService() => _instance;
  DeviceEncryptionService._internal();

  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();

  // In-memory cache of private key
  static RSAPrivateKey? _cachedPrivateKey;
  static RSAPublicKey? _cachedPublicKey;

  static bool _isInitialized = false;
  static final _initCompleter = Completer<void>();

  static void _dbg(String message) {
    assert(() {
      debugPrint('[E2EE] $message');
      return true;
    }());
  }

  // ==========================================================================
  // KEY GENERATION & STORAGE
  // ==========================================================================

  /// Initialize device encryption keys.
  ///
  /// This method is idempotent - safe to call multiple times.
  /// Returns immediately if keys already exist locally.
  ///
  /// SECURITY: Before initializing, verifies device trust. Untrusted devices
  /// cannot access encryption keys, preventing unauthorized key generation.
  /// 
  /// NOTE: Device trust is checked AFTER keys are uploaded. The public key
  /// upload happens immediately, but encryption session activation waits for trust.
  static Future<void> initialize(User user) async {
    if (_isInitialized) {
      _dbg('Already initialized');
      return;
    }

    if (_initCompleter.isCompleted) {
      _dbg('Initialization already in progress or completed');
      return;
    }

    try {
      _dbg('Initializing device encryption...');

      // SECURITY: Check device trust before activating encryption
      final trustState = await DeviceTrustService.getTrustState(user);
      
      // Update session state with trust status
      if (trustState.isTrusted) {
        DeviceTrustStateManager.markDeviceTrusted();
        _dbg('Device is trusted');
      } else {
        DeviceTrustStateManager.markDevicePendingApproval();
        _dbg('Device pending approval - encryption session deferred');
        // Don't complete the completer - encryption will be unavailable
        // until device is approved
        _initCompleter.completeError(
          DeviceTrustRequiredException('Device requires approval before encryption can be initialized'),
        );
        return;
      }

      _dbg('Device is trusted, proceeding with key initialization');

      // Check if we already have device-specific local keys
      final existingDeviceKey = await _storage.read(key: 'device_private_key');
      if (existingDeviceKey != null) {
        _dbg('Found existing device-specific key, loading...');
        await _loadExistingKey(existingDeviceKey);
        _isInitialized = true;
        _initCompleter.complete();
        _dbg('Device key loaded successfully');
        return;
      }

      // Check for legacy key (restored from backup or old version)
      final legacyKey = await _storage.read(key: 'private_key');
      if (legacyKey != null) {
        _dbg('Found legacy key, migrating to device-specific storage...');
        await _loadExistingKey(legacyKey);
        await _storage.write(key: 'device_private_key', value: legacyKey);
        _isInitialized = true;
        _initCompleter.complete();
        _dbg('Legacy key migrated and loaded successfully');
        return;
      }

      // Generate new device keypair
      _dbg('Generating new device keypair...');
      await _generateAndStoreKeys(user);

      _isInitialized = true;
      _initCompleter.complete();
      
      // Mark encryption as active (both key uploaded and device trusted)
      DeviceTrustStateManager.markEncryptionActive();
      _dbg('Device encryption initialized successfully');
    } catch (e, st) {
      _dbg('Failed to initialize device encryption: $e');
      if (kDebugMode) debugPrintStack(stackTrace: st);
      _initCompleter.completeError(e);
      rethrow;
    }
  }

  /// Initialize keys after device is approved.
  ///
  /// Called by AuthService when device trust is granted.
  static Future<void> initializeAfterApproval(User user) async {
    _dbg('initializeAfterApproval: START');

    // Reset initialization state
    _isInitialized = false;
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
    
    // Re-initialize
    final newCompleter = Completer<void>();
    try {
      // Check if we already have device-specific local keys
      final existingDeviceKey = await _storage.read(key: 'device_private_key');
      if (existingDeviceKey != null) {
        _dbg('Found existing device-specific key, loading...');
        await _loadExistingKey(existingDeviceKey);
        _isInitialized = true;
        newCompleter.complete();
        _dbg('Device key loaded successfully');
        return;
      }

      // Check for legacy key (restored from backup)
      final legacyKey = await _storage.read(key: 'private_key');
      if (legacyKey != null) {
        _dbg('Found legacy key from backup, migrating to device-specific storage...');
        // Load the legacy key
        await _loadExistingKey(legacyKey);
        // Also save it as device-specific key for future use
        await _storage.write(key: 'device_private_key', value: legacyKey);
        _isInitialized = true;
        newCompleter.complete();
        _dbg('Legacy key migrated and loaded successfully');
        return;
      }

      // Generate new device keypair
      _dbg('No existing keys found, generating new device keypair...');
      await _generateAndStoreKeys(user);

      _isInitialized = true;
      newCompleter.complete();
      _dbg('Device encryption initialized after approval');
    } catch (e) {
      _dbg('Failed to initialize after approval: $e');
      newCompleter.completeError(e);
      rethrow;
    }
  }

  /// Generate new device keypair and store locally.
  ///
  /// Private key stored ONLY in secure local storage.
  /// Public key uploaded to Firestore.
  static Future<void> _generateAndStoreKeys(User user) async {
    _dbg('Generating RSA keypair...');

    // Generate keypair (runs in isolate via RSAHelper)
    final pair = await RSAHelper.generateKeyPair();
    final publicKey = pair.publicKey;
    final privateKey = pair.privateKey;

    // Serialize keys
    final nStr = publicKey.modulus.toString();
    final eStr = publicKey.exponent.toString();
    final dStr = privateKey.privateExponent.toString();
    final pStr = privateKey.p.toString();
    final qStr = privateKey.q.toString();

    // Store private key locally ONLY
    final privateKeyData = jsonEncode({
      'n': nStr,
      'e': eStr,
      'd': dStr,
      'p': pStr,
      'q': qStr,
    });

    await _storage.write(
      key: 'device_private_key',
      value: privateKeyData,
    );

    _dbg('Private key stored locally');

    // Cache in memory
    _cachedPrivateKey = privateKey;
    _cachedPublicKey = publicKey;

    // Upload public key to device registry
    final deviceId = await DeviceService.getDeviceId();

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('devices')
        .doc(deviceId)
        .set({
      'publicKey': {
        'n': nStr,
        'e': eStr,
      },
      'keyUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _dbg('Public key uploaded for device: $deviceId');
  }

  /// Load existing key from secure storage.
  static Future<void> _loadExistingKey(String privateKeyJson) async {
    try {
      final keyData = jsonDecode(privateKeyJson) as Map<String, dynamic>;

      final n = BigInt.parse(keyData['n'] as String);
      final e = BigInt.parse(keyData['e'] as String);
      final d = BigInt.parse(keyData['d'] as String);
      final p = BigInt.parse(keyData['p'] as String);
      final q = BigInt.parse(keyData['q'] as String);

      _cachedPublicKey = RSAPublicKey(n, e);
      _cachedPrivateKey = RSAPrivateKey(n, d, p, q);

      _dbg('Device key loaded into memory');
    } catch (e) {
      _dbg('Failed to parse device key: $e');
      // Delete corrupted key
      await _storage.delete(key: 'device_private_key');
      rethrow;
    }
  }

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  /// Get this device's public key.
  /// Returns null if not initialized.
  static RSAPublicKey? getPublicKey() {
    return _cachedPublicKey;
  }

  /// Get this device's private key.
  /// Returns null if not initialized.
  static RSAPrivateKey? getPrivateKey() {
    return _cachedPrivateKey;
  }

  /// Check if device encryption is ready.
  static bool get isReady => _isInitialized && _cachedPrivateKey != null;

  /// Wait for initialization to complete.
  static Future<void> get ready => _initCompleter.future;

  // ==========================================================================
  // MESSAGE ENCRYPTION (Multi-device)
  // ==========================================================================

  /// Encrypt a message for a recipient.
  ///
  /// For multi-device support, we need to encrypt for ALL of the recipient's
  /// devices. Each device gets its own encrypted payload.
  ///
  /// Returns: Map<deviceId, encryptedPayload>
  static Future<Map<String, String>?> encryptForRecipient({
    required String message,
    required String recipientUid,
  }) async {
    if (!isReady) {
      _dbg('Device encryption not ready');
      return null;
    }

    try {
      _dbg('Encrypting for recipient: $recipientUid');

      // Get recipient's devices
      final devicesSnapshot = await _firestore
          .collection('users')
          .doc(recipientUid)
          .collection('devices')
          .where('revoked', isEqualTo: false)
          .get();

      if (devicesSnapshot.docs.isEmpty) {
        _dbg('No active devices for recipient');
        return null;
      }

      final encryptedPayloads = <String, String>{};

      for (final doc in devicesSnapshot.docs) {
        final deviceId = doc.id;
        final data = doc.data();
        final publicKeyData = data['publicKey'] as Map<String, dynamic>?;

        if (publicKeyData == null) {
          _dbg('Device $deviceId has no public key, skipping');
          continue;
        }

        try {
          // Reconstruct recipient's public key
          final recipientN = BigInt.parse(publicKeyData['n'] as String);
          final recipientE = BigInt.parse(publicKeyData['e'] as String);
          final recipientPublicKey = RSAPublicKey(recipientN, recipientE);

          // Encrypt message for this device
          final encrypted = await RSAHelper.encrypt(message, recipientPublicKey);
          encryptedPayloads[deviceId] = encrypted;

          _dbg('Encrypted for device: $deviceId');
        } catch (e) {
          _dbg('Failed to encrypt for device $deviceId: $e');
          // Continue with other devices
        }
      }

      if (encryptedPayloads.isEmpty) {
        _dbg('Failed to encrypt for any device');
        return null;
      }

      _dbg('Encrypted for ${encryptedPayloads.length} devices');
      return encryptedPayloads;
    } catch (e) {
      _dbg('Encryption failed: $e');
      return null;
    }
  }

  /// Decrypt a message intended for this device.
  ///
  /// The message should be from the encrypted payloads map.
  static Future<String?> decrypt(String encryptedMessage) async {
    if (!isReady) {
      _dbg('Device encryption not ready');
      return null;
    }

    try {
      final decrypted = await RSAHelper.decrypt(
        encryptedMessage,
        _cachedPrivateKey!,
      );
      return decrypted;
    } catch (e) {
      _dbg('Decryption failed: $e');
      return null;
    }
  }

  // ==========================================================================
  // DEVICE MANAGEMENT
  // ==========================================================================

  /// Encrypt with a specific public key (helper for multi-device).
  /// This doesn't require this device to be initialized.
  static Future<String?> encryptWithPublicKey({
    required String plaintext,
    required RSAPublicKey publicKey,
  }) async {
    try {
      return await RSAHelper.encrypt(plaintext, publicKey);
    } catch (e) {
      _dbg('Encryption with public key failed: $e');
      return null;
    }
  }

  /// Get all device public keys for a user.
  /// Used when sending messages to encrypt for all devices.
  ///
  /// SECURITY: Only returns keys for TRUSTED devices. Messages will not
  /// be encrypted for untrusted or revoked devices.
  static Future<Map<String, RSAPublicKey>> getDevicePublicKeys(String uid) async {
    final result = <String, RSAPublicKey>{};

    try {
      _dbg('Fetching trusted device keys for $uid');
      
      final snapshot = await _firestore
          .collection('users')
          .doc(uid)
          .collection('devices')
          .where('revoked', isEqualTo: false)
          .where('trusted', isEqualTo: true) // SECURITY: Only trusted devices
          .get();

      for (final doc in snapshot.docs) {
        final publicKeyData = doc.data()['publicKey'] as Map<String, dynamic>?;
        if (publicKeyData == null) continue;

        try {
          final n = BigInt.parse(publicKeyData['n'] as String);
          final e = BigInt.parse(publicKeyData['e'] as String);
          result[doc.id] = RSAPublicKey(n, e);
          _dbg('Loaded key for trusted device: ${doc.id}');
        } catch (e) {
          _dbg('Failed to parse public key for ${doc.id}: $e');
        }
      }

      _dbg('Found ${result.length} trusted devices with keys');
    } catch (e) {
      _dbg('Failed to get device public keys: $e');
    }

    return result;
  }

  /// Rotate device keys (in case of compromise).
  ///
  /// Generates new keypair and updates Firestore.
  /// Old messages encrypted with old key will be undecryptable.
  static Future<void> rotateKeys(User user) async {
    _dbg('Rotating device keys...');

    // Clear existing keys
    await _storage.delete(key: 'device_private_key');
    _cachedPrivateKey = null;
    _cachedPublicKey = null;
    _isInitialized = false;

    // Generate new keys
    await initialize(user);

    _dbg('Device keys rotated successfully');
  }

  /// Reset device encryption (logout).
  static Future<void> reset() async {
    _dbg('Resetting device encryption...');
    _cachedPrivateKey = null;
    _cachedPublicKey = null;
    _isInitialized = false;
    // Note: We do NOT delete the local key on logout
    // It will be reused on next login (idempotent)
  }

  /// Clear device keys completely (dangerous - for testing only).
  static Future<void> clearKeys() async {
    _dbg('Clearing device keys...');
    await _storage.delete(key: 'device_private_key');
    _cachedPrivateKey = null;
    _cachedPublicKey = null;
    _isInitialized = false;
  }
}

/// Extension to check if device encryption is ready for use
extension DeviceEncryptionServiceExtension on DeviceEncryptionService {
  static bool get isReady => DeviceEncryptionService.isReady;
}
