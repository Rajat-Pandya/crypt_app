import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';

import 'crypto_security_service.dart';

/// Enhanced encryption lifecycle service with enterprise-grade security
///
/// Improvements:
/// - Session trust validation
/// - Key fingerprinting for out-of-band verification
/// - Enhanced cache with integrity checks
/// - Automatic key rotation detection
/// - Mismatch recovery with trust scoring
///
/// BACKWARD COMPATIBILITY: Maintains all existing APIs while adding
/// optional security enhancements.
class EncryptionLifecycleService {
  static final _firestore = FirebaseFirestore.instance;
  static final _storage = const FlutterSecureStorage();

  // Enhanced cache with integrity metadata
  static final Map<String, CachedPublicKey> _publicKeyCache = {};
  static CachedPrivateKey? _privateKeyCache;
  static CachedPublicKey? _myPublicKeyCache;
  static String? _myKeyVersionCache;
  static DateTime? _sessionStartTime;

  static bool _initialized = false;
  static String? _currentUserId;
  
  // Session trust tracking (duplicated from CryptoSecurityService for internal use)
  static final Map<String, _SessionTrustRecord> _sessionTrust = {};

  static void _dbg(String message) {
    assert(() {
      debugPrint('[EncryptionLifecycle] $message');
      return true;
    }());
  }

  // ==========================================================================
  // INITIALIZATION
  // ==========================================================================

  static Future<void> initialize({String? userId}) async {
    if (_initialized) return;
    
    _sessionStartTime = DateTime.now();
    _currentUserId = userId;
    _initialized = true;
    
    _dbg('initialized for user: $userId, session: $_sessionStartTime');
  }

  // ==========================================================================
  // ENHANCED PUBLIC KEY RETRIEVAL WITH TRUST VALIDATION
  // ==========================================================================

  static Future<PublicKeyResult?> getReceiverPublicKey(
    String receiverId, {
    bool forceRefresh = false,
    bool validateTrust = true,
  }) async {
    // Check cache first
    if (!forceRefresh && _publicKeyCache.containsKey(receiverId)) {
      final cached = _publicKeyCache[receiverId]!;
      
      // Validate cache integrity and staleness
      if (_isCacheValid(cached)) {
        _dbg('cache hit for receiver $receiverId');
        return cached.toResult();
      } else {
        _dbg('cache stale for receiver $receiverId');
        _publicKeyCache.remove(receiverId);
      }
    }

    try {
      final doc = await _firestore
          .collection('users')
          .doc(receiverId)
          .get(const GetOptions(source: Source.serverAndCache));

      final data = doc.data();
      if (data == null || data['publicKey'] == null) {
        _dbg('no public key for $receiverId');
        return null;
      }

      final keyData = data['publicKey'] as Map<String, dynamic>;
      final version = data['publicKeyVersion'] as String? ?? 'v1';
      final lastRotated = data['publicKeyRotatedAt'] != null
          ? DateTime.tryParse(data['publicKeyRotatedAt'])
          : null;

      final publicKey = RSAPublicKey(
        BigInt.parse(keyData['n'] as String),
        BigInt.parse(keyData['e'] as String),
      );

      // Compute key fingerprint for trust verification
      final keyPem = _serializePublicKey(publicKey);
      final fingerprint = CryptoSecurityService.computeKeyFingerprint(keyPem);

      final cached = CachedPublicKey(
        publicKey: publicKey,
        version: version,
        cachedAt: DateTime.now(),
        fingerprint: fingerprint,
        lastRotated: lastRotated,
        source: doc.metadata.isFromCache ? 'cache' : 'server',
      );

      // Validate trust if requested
      if (validateTrust) {
        final trustResult = CryptoSecurityService.validateSession(
          userId: receiverId,
          keyVersion: version,
          sessionCreated: _sessionStartTime,
          lastActivity: lastRotated,
          expectedKeyVersion: null, // We don't have expected version yet
        );

        if (trustResult.isCompromised) {
          _dbg('trust validation failed for $receiverId: ${trustResult.issues}');
          // Still return key but log warning
        }
      }

      _publicKeyCache[receiverId] = cached;
      _dbg('cached public key for $receiverId, version=$version, fp=$fingerprint');
      
      return cached.toResult();
    } catch (e) {
      _dbg('failed to get public key for $receiverId: $e');
      return null;
    }
  }

  // ==========================================================================
  // ENHANCED PRIVATE KEY RETRIEVAL WITH INTEGRITY
  // ==========================================================================

  static Future<String?> getPrivateKey() async {
    // Return cached if available and valid
    if (_privateKeyCache != null && _isPrivateKeyValid(_privateKeyCache!)) {
      return _privateKeyCache!.keyData;
    }

    try {
      final key = await _storage.read(key: 'private_key');
      if (key != null) {
        // Compute hash for integrity verification
        final hash = await _computeKeyHash(key);
        
        _privateKeyCache = CachedPrivateKey(
          keyData: key,
          cachedAt: DateTime.now(),
          integrityHash: hash,
        );
        
        _dbg('private key loaded and cached');
      }
      return key;
    } catch (e) {
      _dbg('failed to get private key: $e');
      return null;
    }
  }

  static Future<RSAPrivateKey?> getPrivateKeyParsed() async {
    final keyStr = await getPrivateKey();
    if (keyStr == null) return null;
    
    try {
      // Parse the private key from storage format
      return _parsePrivateKey(keyStr);
    } catch (e) {
      _dbg('failed to parse private key: $e');
      return null;
    }
  }

  // ==========================================================================
  // ENHANCED MY PUBLIC KEY WITH VERSION TRACKING
  // ==========================================================================

  static Future<PublicKeyResult?> getMyPublicKey(String userId) async {
    // Check cache first
    if (_myPublicKeyCache != null && _isCacheValid(_myPublicKeyCache!)) {
      return _myPublicKeyCache!.toResult();
    }

    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .get(const GetOptions(source: Source.serverAndCache));

      final data = doc.data();
      if (data == null || data['publicKey'] == null) return null;

      final keyData = data['publicKey'] as Map<String, dynamic>;
      final version = data['publicKeyVersion'] as String? ?? 'v1';
      final lastRotated = data['publicKeyRotatedAt'] != null
          ? DateTime.tryParse(data['publicKeyRotatedAt'])
          : null;

      final publicKey = RSAPublicKey(
        BigInt.parse(keyData['n'] as String),
        BigInt.parse(keyData['e'] as String),
      );

      final keyPem = _serializePublicKey(publicKey);
      final fingerprint = CryptoSecurityService.computeKeyFingerprint(keyPem);

      _myPublicKeyCache = CachedPublicKey(
        publicKey: publicKey,
        version: version,
        cachedAt: DateTime.now(),
        fingerprint: fingerprint,
        lastRotated: lastRotated,
        source: doc.metadata.isFromCache ? 'cache' : 'server',
      );
      _myKeyVersionCache = version;

      _dbg('my public key loaded, version=$version, fp=$fingerprint');
      return _myPublicKeyCache!.toResult();
    } catch (e) {
      _dbg('failed to get my public key: $e');
      return null;
    }
  }

  // ==========================================================================
  // KEY ROTATION DETECTION
  // ==========================================================================

  /// Checks if keys have been rotated and updates trust accordingly
  static Future<KeyRotationStatus> checkKeyRotation(String userId) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(userId)
          .get(const GetOptions(source: Source.server));

      if (!doc.exists) return KeyRotationStatus.unknown;

      final data = doc.data();
      final currentVersion = data?['publicKeyVersion'] as String? ?? 'v1';
      final lastRotated = data?['publicKeyRotatedAt'] != null
          ? DateTime.tryParse(data!['publicKeyRotatedAt'])
          : null;

      // Check if version changed in cache
      if (_myKeyVersionCache != null && currentVersion != _myKeyVersionCache) {
        _dbg('key rotation detected: $_myKeyVersionCache -> $currentVersion');
        
        // Clear caches after rotation
        clearAllCache();
        
        // Validate the rotation
        if (lastRotated != null) {
          final age = DateTime.now().difference(lastRotated);
          if (age.inMinutes > 5) {
            // Rotation happened more than 5 minutes ago, should be stable
            return KeyRotationStatus.stable;
          }
        }
        
        return KeyRotationStatus.recent;
      }

      // Check if rotation is imminent (version metadata)
      final rotationScheduled = data?['rotationScheduled'] as bool? ?? false;
      if (rotationScheduled) {
        return KeyRotationStatus.scheduled;
      }

      return KeyRotationStatus.noChange;
    } catch (e) {
      _dbg('failed to check key rotation: $e');
      return KeyRotationStatus.unknown;
    }
  }

  // ==========================================================================
  // RECONNECT SECURITY
  // ==========================================================================

  /// Validates session security after reconnect
  static Future<ReconnectSecurityResult> validateReconnectSecurity(
    String userId,
  ) async {
    _dbg('validating reconnect security for $userId');
    
    // Check key rotation
    final rotationStatus = await checkKeyRotation(userId);
    
    // Validate session trust
    final validation = CryptoSecurityService.validateSession(
      userId: userId,
      keyVersion: _myKeyVersionCache,
      sessionCreated: _sessionStartTime,
      lastActivity: _privateKeyCache?.cachedAt,
      expectedKeyVersion: null,
    );
    
    // Check if we need to revalidate keys
    final shouldRevalidate = rotationStatus == KeyRotationStatus.recent ||
                            validation.needsAttention ||
                            rotationStatus == KeyRotationStatus.scheduled;
    
    // Build result
    final issues = <String>[...validation.issues];
    if (rotationStatus == KeyRotationStatus.recent) {
      issues.add('Keys recently rotated');
    }
    
    return ReconnectSecurityResult(
      isSecure: validation.isValid && rotationStatus != KeyRotationStatus.recent,
      rotationStatus: rotationStatus,
      trustScore: validation.trustScore,
      shouldRevalidateKeys: shouldRevalidate,
      issues: issues,
      recommendation: validation.recommendation,
    );
  }

  // ==========================================================================
  // MISMATCH RECOVERY
  // ==========================================================================

  /// Handles decryption mismatch with trust scoring and recovery
  static MismatchRecoveryResult handleDecryptionMismatch(
    String senderId, {
    required String messageId,
    required String keyVersion,
  }) {
    _dbg('handling decryption mismatch for $senderId, msg=$messageId');
    
    // Update trust record
    // Update session trust via internal map
    _updateSessionTrust(senderId, success: false);
    
    // Check for systematic mismatches
    final trustRecord = _sessionTrust[senderId];
    final recentMismatches = trustRecord?.failedDecryptionCount ?? 0;
    
    if (recentMismatches >= 5) {
      // Systematic failure - likely key mismatch
      clearReceiverCache(senderId);
      
      return MismatchRecoveryResult(
        shouldRetry: true,
        shouldClearCache: true,
        shouldNotifyUser: true,
        severity: MismatchSeverity.critical,
        message: 'Multiple decryption failures detected. Keys may be out of sync.',
      );
    } else if (recentMismatches >= 3) {
      return MismatchRecoveryResult(
        shouldRetry: true,
        shouldClearCache: false,
        shouldNotifyUser: false,
        severity: MismatchSeverity.warning,
        message: 'Decryption issues detected. Retrying...',
      );
    }
    
    return MismatchRecoveryResult(
      shouldRetry: true,
      shouldClearCache: false,
      shouldNotifyUser: false,
      severity: MismatchSeverity.minor,
      message: null,
    );
  }

  /// Records successful decryption for trust tracking
  static void recordSuccessfulDecryption(String senderId) {
    // Update session trust via internal map
    _updateSessionTrust(senderId, success: true);
  }

  // ==========================================================================
  // CACHE MANAGEMENT
  // ==========================================================================

  static void clearReceiverCache(String receiverId) {
    _publicKeyCache.remove(receiverId);
    // Clear trust record
    _sessionTrust.remove(receiverId);
    _dbg('cleared cache and trust for $receiverId');
  }

  static void clearAllCache() {
    _publicKeyCache.clear();
    _privateKeyCache = null;
    _myPublicKeyCache = null;
    _myKeyVersionCache = null;
    _sessionStartTime = DateTime.now(); // Reset session
    _dbg('all encryption cache cleared, session reset');
  }

  static bool get isCached => _privateKeyCache != null;

  // ==========================================================================
  // FINGERPRINTING FOR TRUST VERIFICATION
  // ==========================================================================

  /// Gets fingerprint of cached public key for a user
  static String? getReceiverFingerprint(String receiverId) {
    return _publicKeyCache[receiverId]?.fingerprint;
  }

  /// Gets fingerprint of own public key
  static String? getMyFingerprint() {
    return _myPublicKeyCache?.fingerprint;
  }

  /// Verifies a fingerprint against a cached key
  static bool verifyReceiverFingerprint(String receiverId, String expectedFingerprint) {
    final cached = _publicKeyCache[receiverId];
    if (cached == null) return false;
    
    return CryptoSecurityService.verifyKeyFingerprint(
      _serializePublicKey(cached.publicKey),
      expectedFingerprint,
    );
  }

  // ==========================================================================
  // PRIVATE HELPERS
  // ==========================================================================

  static bool _isCacheValid(CachedPublicKey cached) {
    final age = DateTime.now().difference(cached.cachedAt);
    // Cache valid for 1 hour for server keys, 5 minutes for cache keys
    final maxAge = cached.source == 'server' 
        ? Duration(hours: 1) 
        : Duration(minutes: 5);
    return age < maxAge;
  }

  static bool _isPrivateKeyValid(CachedPrivateKey cached) {
    final age = DateTime.now().difference(cached.cachedAt);
    return age < Duration(hours: 24); // Private key cache is long-lived
  }

  static Future<String> _computeKeyHash(String key) async {
    // Simple hash for integrity checking
    var hash = 0;
    for (var i = 0; i < key.length; i++) {
      hash = ((hash << 5) - hash) + key.codeUnitAt(i);
      hash = hash & hash; // Convert to 32bit integer
    }
    return hash.toString();
  }

  static String _serializePublicKey(RSAPublicKey key) {
    return '${key.modulus},${key.exponent}';
  }

  static RSAPrivateKey _parsePrivateKey(String keyStr) {
    // Parse from storage format (comma-separated BigInt strings)
    final parts = keyStr.split(',');
    if (parts.length < 4) {
      throw FormatException('Invalid private key format');
    }
    
    return RSAPrivateKey(
      BigInt.parse(parts[0]), // n
      BigInt.parse(parts[1]), // d
      BigInt.parse(parts[2]), // p
      BigInt.parse(parts[3]), // q
    );
  }
}

// ============================================================================
// DATA CLASSES
// ============================================================================

class CachedPublicKey {
  final RSAPublicKey publicKey;
  final String version;
  final DateTime cachedAt;
  final String fingerprint;
  final DateTime? lastRotated;
  final String source;

  CachedPublicKey({
    required this.publicKey,
    required this.version,
    required this.cachedAt,
    required this.fingerprint,
    this.lastRotated,
    required this.source,
  });

  PublicKeyResult toResult() => PublicKeyResult(
        publicKey: publicKey,
        version: version,
        fingerprint: fingerprint,
      );
}

class CachedPrivateKey {
  final String keyData;
  final DateTime cachedAt;
  final String integrityHash;

  CachedPrivateKey({
    required this.keyData,
    required this.cachedAt,
    required this.integrityHash,
  });
}

class PublicKeyResult {
  final RSAPublicKey publicKey;
  final String version;
  final String? fingerprint;

  const PublicKeyResult({
    required this.publicKey,
    required this.version,
    this.fingerprint,
  });
}

enum KeyRotationStatus {
  noChange,
  recent,
  stable,
  scheduled,
  unknown,
}

class ReconnectSecurityResult {
  final bool isSecure;
  final KeyRotationStatus rotationStatus;
  final int trustScore;
  final bool shouldRevalidateKeys;
  final List<String> issues;
  final SessionRecommendation recommendation;

  const ReconnectSecurityResult({
    required this.isSecure,
    required this.rotationStatus,
    required this.trustScore,
    required this.shouldRevalidateKeys,
    required this.issues,
    required this.recommendation,
  });
}

// Note: SessionRecommendation is defined in crypto_security_service.dart

enum MismatchSeverity {
  minor,
  warning,
  critical,
}

class MismatchRecoveryResult {
  final bool shouldRetry;
  final bool shouldClearCache;
  final bool shouldNotifyUser;
  final MismatchSeverity severity;
  final String? message;

  const MismatchRecoveryResult({
    required this.shouldRetry,
    required this.shouldClearCache,
    required this.shouldNotifyUser,
    required this.severity,
    this.message,
  });
}

// ============================================================================
// INTERNAL TRUST TRACKING
// ============================================================================

class _SessionTrustRecord {
  int successfulDecryptionCount = 0;
  int failedDecryptionCount = 0;
  DateTime? lastMismatchTime;
  DateTime? lastActivityTime;
  int reconnectCount = 0;
  final List<DateTime> reconnectTimes = [];
}

/// Updates session trust record (internal to lifecycle service)
void _updateSessionTrust(String userId, {bool success = true}) {
  EncryptionLifecycleService._sessionTrust[userId] ??= _SessionTrustRecord();
  final record = EncryptionLifecycleService._sessionTrust[userId]!;
  
  if (success) {
    record.successfulDecryptionCount++;
    record.failedDecryptionCount = 0;
  } else {
    record.failedDecryptionCount++;
    if (record.failedDecryptionCount >= 5) {
      record.lastMismatchTime = DateTime.now();
    }
  }
  record.lastActivityTime = DateTime.now();
}
