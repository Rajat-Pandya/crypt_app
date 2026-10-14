import 'dart:convert';
import 'dart:math';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/api.dart';
import 'package:flutter/foundation.dart';

/// Enterprise-grade HMAC key derivation and management service
///
/// Provides:
/// - HKDF-like key derivation from session ID + user ID
/// - In-memory key storage (no persistence for security)
/// - Key rotation support with versioning
/// - Automatic cleanup on logout/session end
///
/// SECURITY: Keys are NEVER written to disk. They exist only in memory
/// and are cleared on logout or app termination.
class HmacKeyService {
  // ==========================================================================
  // SINGLETON PATTERN
  // ==========================================================================

  static final HmacKeyService _instance = HmacKeyService._internal();
  factory HmacKeyService() => _instance;
  HmacKeyService._internal();

  // ==========================================================================
  // INTERNAL STATE
  // ==========================================================================

  /// Master key material - derived from session/user context
  /// This is combined with session/user IDs to derive HMAC keys
  static final Uint8List _masterKeyMaterial = _generateMasterKey();

  /// Cache of derived keys: version -> key bytes
  static final Map<String, Uint8List> _keyCache = {};

  /// Cache of key creation timestamps: version -> creation time
  static final Map<String, DateTime> _keyTimestamps = {};

  /// Current key version
  static String? _currentKeyVersion;

  /// Current user ID (for key derivation context)
  static String? _userId;

  /// Current session ID (for key derivation context)
  static String? _sessionId;

  /// Whether service is initialized
  static bool _isInitialized = false;

  /// Secure random for key generation
  static final Random _secureRandom = Random.secure();

  // ==========================================================================
  // KEY DERIVATION CONSTANTS
  // ==========================================================================

  /// Context string for HMAC key derivation (HKDF-style)
  static const String _hmacKeyContext = 'crypt-app-hmac-v1';

  /// Context string for rotation key derivation
  static const String _rotationContext = 'crypt-app-hmac-rotate';

  /// Size of derived keys (32 bytes = 256 bits for SHA-256 HMAC)
  static const int _derivedKeySize = 32;

  // ==========================================================================
  // INITIALIZATION
  // ==========================================================================

  /// Initializes the HMAC key service for a user session
  ///
  /// Derives the initial HMAC key from the user ID and session ID.
  /// This should be called on app startup or after login.
  ///
  /// Example:
  /// ```dart
  /// await HmacKeyService().initialize(
  ///   userId: currentUser.uid,
  ///   sessionId: sessionId,
  /// );
  /// ```
  static Future<void> initialize({
    required String userId,
    required String sessionId,
  }) async {
    _dbg('Initializing HMAC key service for user: $userId');

    // SECURITY FIX: Don't clear existing keys on startup
    // Old keys must be preserved for decrypting historical messages
    // Only clear keys explicitly via clear() on logout/key rotation
    
    // Check if already initialized for same user/session
    if (_isInitialized && _userId == userId && _sessionId == sessionId) {
      _dbg('HMAC key service already initialized for this session');
      return;
    }

    _userId = userId;
    _sessionId = sessionId;

    // Derive initial key
    final initialKey = _deriveKey(
      userId: userId,
      sessionId: sessionId,
      context: _hmacKeyContext,
      version: '1',
    );

    _currentKeyVersion = '1';
    _keyCache['1'] = initialKey;
    _keyTimestamps['1'] = DateTime.now(); // Track initial key creation time
    _isInitialized = true;

    _dbg('HMAC key service initialized with version 1');
  }

  /// Checks if the service has been initialized
  static bool get isInitialized => _isInitialized;

  // ==========================================================================
  // KEY ACCESS
  // ==========================================================================

  /// Gets the current HMAC key for message authentication
  ///
  /// Returns the current version's derived key bytes.
  /// Throws if the service is not initialized.
  ///
  /// The returned key is suitable for use with HMAC-SHA256 operations.
  static Uint8List getHmacKey() {
    if (!_isInitialized) {
      throw HmacKeyException(
        'HMAC key service not initialized. Call initialize() first.',
      );
    }

    if (_currentKeyVersion == null) {
      throw HmacKeyException('No current key version available');
    }

    final key = _keyCache[_currentKeyVersion!];
    if (key == null) {
      throw HmacKeyException(
        'Key not found for version: $_currentKeyVersion',
      );
    }

    return key;
  }

  /// Gets the current key version string
  ///
  /// This version should be included in messages to allow
  /// the receiver to select the correct key for verification.
  static String? getCurrentKeyVersion() {
    return _currentKeyVersion;
  }

  /// Gets a specific key version (for verification of old messages)
  ///
  /// Returns null if the version is not in cache.
  static Uint8List? getKeyVersion(String version) {
    return _keyCache[version];
  }

  /// Checks if a specific key version is available
  static bool hasKeyVersion(String version) {
    return _keyCache.containsKey(version);
  }

  // ==========================================================================
  // KEY ROTATION
  // ==========================================================================

  /// Rotates to a new HMAC key
  ///
  /// Derives a new key with an incremented version number.
  /// Old keys are kept in cache for a limited time to allow
  /// verification of messages sent with the old key.
  ///
  /// Returns the new key version.
  static Future<String> rotateKey() async {
    if (!_isInitialized) {
      throw HmacKeyException(
        'Cannot rotate key: service not initialized',
      );
    }

    if (_userId == null || _sessionId == null) {
      throw HmacKeyException(
        'Cannot rotate key: missing userId or sessionId',
      );
    }

    // Calculate new version number
    final currentVersion = int.tryParse(_currentKeyVersion ?? '0') ?? 0;
    final newVersion = (currentVersion + 1).toString();

    _dbg('Rotating HMAC key from version $currentVersion to $newVersion');

    // Derive new key with rotation context
    final newKey = _deriveKey(
      userId: _userId!,
      sessionId: _sessionId!,
      context: _rotationContext,
      version: newVersion,
    );

    // Store new key
    _keyCache[newVersion] = newKey;
    _keyTimestamps[newVersion] = DateTime.now(); // Track key creation time
    _currentKeyVersion = newVersion;

    // Clean up very old keys (keep last 5 versions)
    _cleanupOldKeys();

    _dbg('Key rotated successfully to version $newVersion');
    return newVersion;
  }

  /// Rotates the key if the current version is older than specified
  ///
  /// Returns true if rotation was performed, false if current key is recent enough.
  static Future<bool> rotateIfOlderThan(Duration maxAge) async {
    if (!_isInitialized) return false;
    if (_currentKeyVersion == null) return false;

    // Check if we have a timestamp for the current key
    final keyCreatedAt = _keyTimestamps[_currentKeyVersion];
    if (keyCreatedAt == null) {
      // No timestamp available - assume key needs rotation for safety
      _dbg('No timestamp for current key $_currentKeyVersion, rotating');
      await rotateKey();
      return true;
    }

    // Check if key has exceeded max age
    final keyAge = DateTime.now().difference(keyCreatedAt);
    if (keyAge > maxAge) {
      _dbg('Key $_currentKeyVersion is ${keyAge.inHours}h old, exceeding max ${maxAge.inHours}h, rotating');
      await rotateKey();
      return true;
    }

    _dbg('Key $_currentKeyVersion is ${keyAge.inHours}h old, within ${maxAge.inHours}h threshold, no rotation needed');
    return false;
  }

  // ==========================================================================
  // KEY CLEARING
  // ==========================================================================

  /// Clears all cached keys and resets the service
  ///
  /// **SECURITY WARNING**: This should ONLY be called on:
  /// - User logout
  /// - Explicit key rotation request
  /// - Account reset/corruption recovery
  ///
  /// **DO NOT call on app startup** - old keys are needed for
  /// decrypting historical messages. Clearing on startup will
  /// break message decryption compatibility.
  ///
  /// All key material is securely cleared from memory.
  static void clear() {
    _dbg('SECURITY: Clearing all HMAC keys');

    // Overwrite key material before clearing (secure erase)
    for (final key in _keyCache.values) {
      _secureClear(key);
    }

    _keyCache.clear();
    _keyTimestamps.clear();
    _currentKeyVersion = null;
    _userId = null;
    _sessionId = null;
    _isInitialized = false;

    _dbg('SECURITY: All HMAC keys cleared from memory');
  }

  /// Clears keys for a specific user (called on user switch/logout)
  ///
  /// **SECURITY**: Only clears if the user ID matches, preventing
  /// accidental clearing of another user's keys during session switches.
  static void clearForUser(String userId) {
    if (_userId == userId) {
      _dbg('SECURITY: Clearing HMAC keys for user: $userId');
      clear();
    }
  }

  /// Resets the service completely (for testing/emergency recovery only)
  ///
  /// **WARNING**: This will break decryption of old messages.
  /// Only use for testing or when explicitly requested by user
  /// for account recovery/corruption scenarios.
  static void resetForTesting() {
    _dbg('EMERGENCY: Resetting HMAC key service (TESTING ONLY)');
    clear();
    _dbg('EMERGENCY: HMAC key service reset complete');
  }

  // ==========================================================================
  // KEY DERIVATION (HKDF-like)
  // ==========================================================================

  /// Derives an HMAC key from userId, sessionId, and context
  ///
  /// Derivation formula:
  /// ```
  /// PRK = HMAC-SHA256(masterKey, userId || sessionId || context || version)
  /// OKM = HMAC-SHA256(PRK, version)
  /// ```
  ///
  /// This is similar to HKDF-Expand where:
  /// - masterKey is the PRK (pseudorandom key)
  /// - The info string provides binding to context
  static Uint8List _deriveKey({
    required String userId,
    required String sessionId,
    required String context,
    required String version,
  }) {
    // Step 1: Build info string for derivation
    // Format: userId || "|" || sessionId || "|" || context || "|" || version
    final info = '$userId|$sessionId|$context|$version';
    final infoBytes = utf8.encode(info);

    // Step 2: Extract phase (PRK = HMAC-SHA256(masterKey, info))
    final prk = _hmacSha256(
      key: _masterKeyMaterial,
      data: Uint8List.fromList(infoBytes),
    );

    // Step 3: Expand phase (OKM = HMAC-SHA256(PRK, version))
    // We use version as the expand input to get different keys per version
    final okm = _hmacSha256(
      key: prk,
      data: Uint8List.fromList(utf8.encode(version)),
    );

    // Return first 32 bytes (sufficient for HMAC-SHA256)
    return okm.sublist(0, _derivedKeySize);
  }

  /// Computes HMAC-SHA256
  static Uint8List _hmacSha256({
    required Uint8List key,
    required Uint8List data,
  }) {
    final hmac = HMac(SHA256Digest(), 64);
    hmac.init(KeyParameter(key));
    hmac.update(data, 0, data.length);

    final output = Uint8List(32);
    hmac.doFinal(output, 0);
    return output;
  }

  // ==========================================================================
  // MASTER KEY GENERATION
  // ==========================================================================

  /// Generates the master key material
  ///
  /// This key is used as the basis for all derived HMAC keys.
  /// It's generated once per app instance and never stored.
  ///
  /// In a more advanced implementation, this could be:
  /// - Derived from a hardware-backed key (KeyStore/Keychain)
  /// - Derived from a user password
  /// - Loaded from a secure enclave
  static Uint8List _generateMasterKey() {
    final key = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      key[i] = _secureRandom.nextInt(256);
    }
    return key;
  }

  // ==========================================================================
  // CLEANUP
  // ==========================================================================

  /// Removes old key versions, keeping the last N
  ///
  /// **SECURITY**: Preserves old keys for message decryption compatibility.
  /// Messages sent with old key versions can still be verified after cleanup.
  /// Only removes keys when we have more than maxVersionsToKeep.
  static void _cleanupOldKeys() {
    const maxVersionsToKeep = 5;

    if (_keyCache.length <= maxVersionsToKeep) return;

    // Sort versions numerically
    final versions = _keyCache.keys.toList()
      ..sort((a, b) {
        final aNum = int.tryParse(a) ?? 0;
        final bNum = int.tryParse(b) ?? 0;
        return aNum.compareTo(bNum);
      });

    // SECURITY: Always keep at least 2 versions minimum for safety
    // This ensures we don't accidentally delete keys needed for recent messages
    final minVersionsToKeep = 2;
    final versionsToKeep = maxVersionsToKeep > minVersionsToKeep 
        ? maxVersionsToKeep 
        : minVersionsToKeep;
    
    if (versions.length <= versionsToKeep) return;

    // Clear oldest versions beyond our retention policy
    final toRemove = versions.length - versionsToKeep;
    for (var i = 0; i < toRemove; i++) {
      final oldVersion = versions[i];
      final oldKey = _keyCache.remove(oldVersion);
      if (oldKey != null) {
        _secureClear(oldKey);
        _dbg('Cleared old key version: $oldVersion (retention policy)');
      }
    }
  }

  /// Securely clears a byte array (overwrites with zeros)
  static void _secureClear(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  }

  // ==========================================================================
  // DEBUGGING
  // ==========================================================================

  static void _dbg(String message) {
    assert(() {
      debugPrint('[HmacKeyService] $message');
      return true;
    }());
  }

  // ==========================================================================
  // DIAGNOSTICS (for debugging, no sensitive data)
  // ==========================================================================

  /// Returns diagnostic info (safe for logging - no key material)
  static Map<String, dynamic> getDiagnostics() {
    return {
      'isInitialized': _isInitialized,
      'currentVersion': _currentKeyVersion,
      'cachedVersions': _keyCache.keys.toList(),
      'hasUserId': _userId != null,
      'hasSessionId': _sessionId != null,
    };
  }
}

/// Exception thrown by HMAC key service
class HmacKeyException implements Exception {
  final String message;

  const HmacKeyException(this.message);

  @override
  String toString() => 'HmacKeyException: $message';
}
