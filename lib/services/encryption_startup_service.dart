import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/rsa_helper.dart';
import 'key_backup_service.dart';
import 'device_trust_state_manager.dart';

/// Encryption startup states for the state machine
enum EncryptionStartupState {
  /// Initial state - no startup in progress
  idle,

  /// Starting encryption setup
  starting,

  /// Checking for existing local keys
  checkingLocalKeys,

  /// Attempting to restore keys from backup (PBKDF2)
  restoringFromBackup,

  /// Generating new RSA key pair
  generatingKeys,

  /// Syncing public key to Firestore
  syncingToFirestore,

  /// Encryption fully ready
  ready,

  /// Setup completed but with warnings
  readyWithWarnings,

  /// Setup failed
  failed,
}

/// State change event for reactive UI updates
class EncryptionStateEvent {
  final EncryptionStartupState state;
  final DateTime timestamp;
  final String? message;
  final Duration? elapsed;
  final dynamic error;

  const EncryptionStateEvent({
    required this.state,
    required this.timestamp,
    this.message,
    this.elapsed,
    this.error,
  });

  @override
  String toString() {
    final elapsedStr = elapsed != null ? ' (${elapsed!.inMilliseconds}ms)' : '';
    return '[ENC] $state: $message$elapsedStr';
  }
}

/// Result of encryption startup
class EncryptionStartupResult {
  final bool success;
  final EncryptionStartupState finalState;
  final String? error;
  final Duration elapsed;

  const EncryptionStartupResult({
    required this.success,
    required this.finalState,
    this.error,
    required this.elapsed,
  });
}

/// Centralized encryption startup service with state machine.
///
/// CRITICAL ARCHITECTURE PRINCIPLES:
/// 1. NEVER blocks UI navigation
/// 2. Runs ALL heavy operations in background isolates
/// 3. Uses proper state machine with stream-based reactive updates
/// 4. Prevents duplicate startup via singleton guard
/// 5. Caches PBKDF2 results to avoid re-derivation
/// 6. Generates RSA keys in isolate, not on main thread
class EncryptionStartupService {
  static final EncryptionStartupService _instance = EncryptionStartupService._internal();
  factory EncryptionStartupService() => _instance;
  EncryptionStartupService._internal();

  // Dependencies
  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();
  static final _auth = FirebaseAuth.instance;

  // State management
  static EncryptionStartupState _state = EncryptionStartupState.idle;
  static String? _currentUserId;
  static DateTime? _startTime;
  static bool _isInitializing = false;
  static Future<EncryptionStartupResult>? _initializationFuture;

  // Stream controller for reactive UI
  static final _stateController = StreamController<EncryptionStateEvent>.broadcast();

  // Configuration
  static const Duration _maxStartupTime = Duration(seconds: 30);
  static const String _setupDoneKey = 'encryption_setup_done';
  static const String _publicKeyPendingKey = 'public_key_upload_pending';
  static const String _verifiedPublicKeyKey = 'verified_public_key';
  static const Duration _keyCacheTTL = Duration(days: 7);

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  /// Reactive stream of encryption state changes
  static Stream<EncryptionStateEvent> get stateStream => _stateController.stream;

  /// Current encryption state
  static EncryptionStartupState get currentState => _state;

  /// Whether encryption is fully ready
  static bool get isReady =>
      _state == EncryptionStartupState.ready ||
      _state == EncryptionStartupState.readyWithWarnings;

  /// Whether encryption startup is in progress
  static bool get isInProgress =>
      _state != EncryptionStartupState.idle &&
      _state != EncryptionStartupState.ready &&
      _state != EncryptionStartupState.readyWithWarnings &&
      _state != EncryptionStartupState.failed;

  /// Whether encryption has failed
  static bool get hasFailed => _state == EncryptionStartupState.failed;

  /// Current user ID being initialized
  static String? get currentUserId => _currentUserId;

  /// Initialize encryption in BACKGROUND.
  ///
  /// THIS METHOD IS NON-BLOCKING and returns immediately.
  /// The returned Future completes when startup finishes (success or failure).
  /// UI should listen to [stateStream] for reactive updates.
  static Future<EncryptionStartupResult> initialize({
    required User user,
    String? password,
  }) {
    // Singleton guard: prevent duplicate initialization for same user
    if (_isInitializing &&
        _currentUserId == user.uid &&
        _initializationFuture != null) {
      debugPrint('[AUTH] EncryptionStartupService: already initializing for ${user.uid}, returning existing future');
      return _initializationFuture!;
    }

    // If already ready for this user, return immediately
    if (isReady && _currentUserId == user.uid) {
      debugPrint('[AUTH] EncryptionStartupService: already ready for ${user.uid}');
      return Future.value(EncryptionStartupResult(
        success: true,
        finalState: _state,
        elapsed: Duration.zero,
      ));
    }

    // Start new initialization
    _isInitializing = true;
    _currentUserId = user.uid;
    _startTime = DateTime.now();

    debugPrint('[NAV] EncryptionStartupService.initialize: START - uid=${user.uid}, hasPassword=${password != null}');

    _initializationFuture = _runStartupInternal(user, password: password);
    return _initializationFuture!;
  }

  /// Reset state on logout
  static void reset() {
    debugPrint('[AUTH] EncryptionStartupService.reset()');
    _state = EncryptionStartupState.idle;
    _currentUserId = null;
    _startTime = null;
    _isInitializing = false;
    _initializationFuture = null;
    KeyBackupService.clearDerivedKeyCache();
  }

  // ==========================================================================
  // INTERNAL STARTUP FLOW
  // ==========================================================================

  static Future<EncryptionStartupResult> _runStartupInternal(
    User user, {
    String? password,
  }) async {
    final startTime = DateTime.now();

    try {
      // Phase 1: Check for existing local keys (fast, non-blocking)
      _setState(EncryptionStartupState.starting, message: 'Starting encryption setup');
      await Future.delayed(Duration.zero); // Yield to event loop

      _setState(EncryptionStartupState.checkingLocalKeys, message: 'Checking local keys');

      final existingKey = await _storage.read(key: 'private_key');

      if (existingKey != null) {
        debugPrint('[ENC] Found existing local key');

        // Verify key format and sync to Firestore (background)
        final verified = await _verifyAndSyncExistingKey(user, existingKey);

        if (verified) {
          final elapsed = DateTime.now().difference(startTime);
          _setState(
            EncryptionStartupState.ready,
            message: 'Encryption ready (existing key)',
            elapsed: elapsed,
          );
          debugPrint('[READY] Encryption ready in ${elapsed.inMilliseconds}ms');
          _isInitializing = false;
          return EncryptionStartupResult(
            success: true,
            finalState: EncryptionStartupState.ready,
            elapsed: elapsed,
          );
        }

        // Key exists but invalid - archive before deleting, then generate/restore
        debugPrint('[ENC] Existing key invalid, will generate/restore');
        // Archive the invalid key just in case (might be decryptable later)
        final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
        await _storage.write(
          key: 'archived_private_key_invalid_$timestamp',
          value: existingKey,
        );
        debugPrint('[RSA] Archived potentially invalid key as archived_private_key_invalid_$timestamp');
        await _storage.delete(key: 'private_key');
      }

      // Phase 2: No local key - try restore from backup
      if (password != null) {
        _setState(EncryptionStartupState.restoringFromBackup, message: 'Restoring keys from backup...');
        debugPrint('[PBKDF2] Starting key restoration');

        final result = await KeyBackupService.restorePrivateKey(
          user: user,
          password: password,
        );

        switch (result) {
          case KeyRestoreResult.success:
            debugPrint('[RESTORE] Key restored from backup');
            await _storage.write(key: _setupDoneKey, value: 'true');

            final elapsed = DateTime.now().difference(startTime);
            _setState(
              EncryptionStartupState.ready,
              message: 'Keys restored from backup',
              elapsed: elapsed,
            );
            debugPrint('[READY] Encryption ready in ${elapsed.inMilliseconds}ms');
            _isInitializing = false;
            return EncryptionStartupResult(
              success: true,
              finalState: EncryptionStartupState.ready,
              elapsed: elapsed,
            );

          case KeyRestoreResult.noBackup:
            debugPrint('[RESTORE] No backup found, will generate new keys');
            break;

          case KeyRestoreResult.wrongPassword:
            debugPrint('[RESTORE] Wrong password - cannot restore');
            // Continue to generate new keys (will break old messages)
            break;
        }
      }

      // Phase 3: Generate new RSA key pair (in isolate)
      _setState(EncryptionStartupState.generatingKeys, message: 'Generating secure keys...');
      debugPrint('[RSA] Starting key generation in isolate');

      await _generateAndStoreKeys(user, password: password);

      final elapsed = DateTime.now().difference(startTime);
      _setState(
        EncryptionStartupState.ready,
        message: 'New keys generated',
        elapsed: elapsed,
      );
      debugPrint('[READY] Encryption ready in ${elapsed.inMilliseconds}ms');
      _isInitializing = false;
      return EncryptionStartupResult(
        success: true,
        finalState: EncryptionStartupState.ready,
        elapsed: elapsed,
      );

    } catch (e, st) {
      debugPrint('[ENC] Startup error: $e');
      if (kDebugMode) debugPrintStack(stackTrace: st);

      final elapsed = DateTime.now().difference(startTime);
      _setState(
        EncryptionStartupState.failed,
        message: 'Startup failed: $e',
        elapsed: elapsed,
        error: e,
      );
      _isInitializing = false;
      return EncryptionStartupResult(
        success: false,
        finalState: EncryptionStartupState.failed,
        error: e.toString(),
        elapsed: elapsed,
      );
    }
  }

  // ==========================================================================
  // KEY VERIFICATION
  // ==========================================================================

  static Future<bool> _verifyAndSyncExistingKey(User user, String keyJson) async {
    try {
      final keyData = jsonDecode(keyJson) as Map<String, dynamic>;

      // Validate key format
      if (keyData['n'] == null || keyData['e'] == null) {
        debugPrint('[ENC] Invalid key format');
        return false;
      }

      final localModulus = keyData['n'] as String;
      final localExponent = keyData['e'] as String;

      // Check cache first (fastest path)
      final cachedKey = await _getCachedPublicKey();
      if (cachedKey != null && cachedKey['modulus'] == localModulus) {
        debugPrint('[ENC] Using cached public key (TTL valid)');
        await _storage.write(key: _setupDoneKey, value: 'true');
        
        // Mark key as uploaded in session manager
        DeviceTrustStateManager.markKeyUploaded(_keyVersion(localModulus));
        debugPrint('[ENC_SESSION] Key marked as uploaded (cached)');

        // Validate in background (non-blocking)
        _validateCachedKeyInBackground(user.uid, localModulus);
        return true;
      }

      // Check Firestore with short timeout
      try {
        final doc = await _firestore
            .collection('users')
            .doc(user.uid)
            .get()
            .timeout(const Duration(seconds: 3));

        final firestoreKey = doc.data()?['publicKey'];

        if (firestoreKey != null && firestoreKey['n'] == localModulus) {
          debugPrint('[ENC] Key matches Firestore');

          // Cache for fast future logins
          await _cachePublicKey(
            modulus: localModulus,
            exponent: localExponent,
            keyVersion: _keyVersion(localModulus),
          );
          
          // Mark key as uploaded in session manager
          DeviceTrustStateManager.markKeyUploaded(_keyVersion(localModulus));
          debugPrint('[ENC_SESSION] Key marked as uploaded (Firestore verified)');

          await _storage.write(key: _setupDoneKey, value: 'true');
          return true;
        }

        if (firestoreKey != null) {
          debugPrint('[ENC] Key mismatch detected');
          return false;
        }

        // No key in Firestore - upload ours
        debugPrint('[ENC] Uploading public key to Firestore');
        await _firestore.collection('users').doc(user.uid).set({
          'publicKey': {'n': localModulus, 'e': localExponent},
          'publicKeyVersion': _keyVersion(localModulus),
        }, SetOptions(merge: true));

        await _cachePublicKey(
          modulus: localModulus,
          exponent: localExponent,
          keyVersion: _keyVersion(localModulus),
        );

        await _storage.write(key: _setupDoneKey, value: 'true');
        return true;

      } on TimeoutException {
        debugPrint('[ENC] Firestore check timed out, assuming valid');
        await _storage.write(key: _setupDoneKey, value: 'true');
        return true;
      }

    } catch (e) {
      debugPrint('[ENC] Key verification error: $e');
      return false;
    }
  }

  // ==========================================================================
  // KEY GENERATION (In Isolate)
  // ==========================================================================

  static Future<void> _generateAndStoreKeys(User user, {String? password}) async {
    debugPrint('[RSA] Generating RSA key pair in isolate');

    // Generate keys in isolate to not block UI
    // RSAHelper.generateKeyPair() already runs in Isolate.run internally
    final keyPairData = await _generateKeyPairAsync();

    final nStr = keyPairData['n']!;
    final eStr = keyPairData['e']!;
    final privateKeyData = keyPairData['privateKey']!;
    final keyVersion = _keyVersion(nStr);

    // 🔑 MULTI-DEVICE FIX: Archive existing key before overwriting
    // This preserves old keys for decrypting messages sent with previous key versions
    final existingKey = await _storage.read(key: 'private_key');
    if (existingKey != null && existingKey != privateKeyData) {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      await _storage.write(
        key: 'archived_private_key_$timestamp',
        value: existingKey,
      );
      debugPrint('[RSA] Archived existing private key as version $timestamp');
    }

    // Store keys
    await _storage.write(key: 'private_key', value: privateKeyData);
    debugPrint('[RSA] Private key stored');

    // Upload public key with retry logic
    // CRITICAL: Permission errors (App Check, Firestore rules) should be retried
    bool keyUploaded = false;
    int uploadAttempts = 0;
    const maxUploadAttempts = 3;
    
    while (uploadAttempts < maxUploadAttempts && !keyUploaded) {
      uploadAttempts++;
      try {
        debugPrint('[KEY_UPLOAD] Attempt $uploadAttempts/$maxUploadAttempts for uid=${user.uid}');
        
        await _firestore.collection('users').doc(user.uid).set({
          'publicKey': {'n': nStr, 'e': eStr},
          'publicKeyVersion': keyVersion,
          'keyUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        
        debugPrint('[KEY_UPLOAD] SUCCESS: Public key uploaded to Firestore');
        debugPrint('[FIRESTORE_RULES] Write succeeded - user has permission');
        keyUploaded = true;
        
        // Clear any pending flag
        await _storage.delete(key: _publicKeyPendingKey);
        
      } on FirebaseException catch (e) {
        debugPrint('[KEY_UPLOAD] FAILED: ${e.code} - ${e.message}');
        debugPrint('[FIRESTORE_RULES] Error: ${e.code}');
        
        // Handle specific error codes
        if (e.code == 'permission-denied') {
          debugPrint('[FIRESTORE_RULES] PERMISSION_DENIED - Firestore rules blocked write');
          debugPrint('[FIRESTORE_RULES] Ensure rules allow: publicKey, publicKeyVersion, keyUpdatedAt');
        } else if (e.code == 'app-check') {
          debugPrint('[FIRESTORE_RULES] APP_CHECK_FAILED - App Check token invalid');
        }
        
        // Mark as pending for retry
        await _storage.write(key: _publicKeyPendingKey, value: 'true');
        
        // Exponential backoff before retry
        if (uploadAttempts < maxUploadAttempts) {
          final delayMs = (uploadAttempts * 1000); // 1s, 2s
          debugPrint('[KEY_UPLOAD] Retrying in ${delayMs}ms...');
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    }
    
    if (!keyUploaded) {
      debugPrint('[KEY_UPLOAD] FAILED: All $maxUploadAttempts attempts exhausted');
      debugPrint('[KEY_STATUS] Upload is PENDING - will retry on next login');
    }

    // IMMEDIATELY update session state - key uploaded
    // This is independent of device trust status
    if (keyUploaded) {
      DeviceTrustStateManager.markKeyUploaded(keyVersion);
      debugPrint('[ENC_SESSION] Key uploaded: version=$keyVersion');
    }

    // Cache public key
    await _cachePublicKey(
      modulus: nStr,
      exponent: eStr,
      keyVersion: keyVersion,
    );

    // Backup encrypted key if password provided
    if (password != null) {
      try {
        await KeyBackupService.backupPrivateKey(
          user: user,
          privateKeyJson: privateKeyData,
          password: password,
        );
        debugPrint('[BACKUP] Key backed up successfully');
      } catch (e) {
        debugPrint('[BACKUP] Key backup failed: $e');
      }
    }

    await _storage.write(key: _setupDoneKey, value: 'true');
  }

  /// Generate RSA key pair using RSAHelper (already runs in isolate)
  static Future<Map<String, String>> _generateKeyPairAsync() async {
    final pair = await RSAHelper.generateKeyPair();
    final publicKey = pair.publicKey;
    final privateKey = pair.privateKey;

    final nStr = publicKey.modulus.toString();
    final eStr = publicKey.exponent.toString();

    final privateKeyData = jsonEncode({
      'n': nStr,
      'e': eStr,
      'd': privateKey.privateExponent.toString(),
      'p': privateKey.p.toString(),
      'q': privateKey.q.toString(),
    });

    return {
      'n': nStr,
      'e': eStr,
      'privateKey': privateKeyData,
    };
  }

  // ==========================================================================
  // KEY CACHING
  // ==========================================================================

  static Future<Map<String, String>?> _getCachedPublicKey() async {
    try {
      final cached = await _storage.read(key: _verifiedPublicKeyKey);
      if (cached == null) return null;

      final data = jsonDecode(cached) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(data['cachedAt'] as String);

      if (DateTime.now().difference(cachedAt) > _keyCacheTTL) {
        debugPrint('[ENC] Key cache expired');
        return null;
      }

      return {
        'modulus': data['modulus'] as String,
        'exponent': data['exponent'] as String,
      };
    } catch (e) {
      return null;
    }
  }

  static Future<void> _cachePublicKey({
    required String modulus,
    required String exponent,
    required String keyVersion,
  }) async {
    await _storage.write(
      key: _verifiedPublicKeyKey,
      value: jsonEncode({
        'modulus': modulus,
        'exponent': exponent,
        'keyVersion': keyVersion,
        'cachedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  static void _validateCachedKeyInBackground(String uid, String modulus) {
    Future.delayed(const Duration(seconds: 2), () async {
      try {
        final doc = await _firestore.collection('users').doc(uid).get();
        final firestoreKey = doc.data()?['publicKey'];

        if (firestoreKey != null && firestoreKey['n'] != modulus) {
          debugPrint('[ENC] Cache validation: key mismatch detected!');
          await _storage.delete(key: _verifiedPublicKeyKey);
        } else {
          debugPrint('[ENC] Cache validation: key still valid');
        }
      } catch (e) {
        debugPrint('[ENC] Cache validation error: $e');
      }
    });
  }

  static String _keyVersion(String modulus) {
    return modulus.substring(0, 8);
  }

  // ==========================================================================
  // STATE MANAGEMENT
  // ==========================================================================

  static void _setState(
    EncryptionStartupState newState, {
    String? message,
    Duration? elapsed,
    dynamic error,
  }) {
    _state = newState;
    final event = EncryptionStateEvent(
      state: newState,
      timestamp: DateTime.now(),
      message: message,
      elapsed: elapsed ??
          (_startTime != null ? DateTime.now().difference(_startTime!) : null),
      error: error,
    );
    _stateController.add(event);
    debugPrint(event.toString());
  }

  /// Dispose - call on app shutdown
  void dispose() {
    _stateController.close();
  }

  // ==========================================================================
  // PENDING UPLOAD RETRY
  // ==========================================================================

  /// Check if there's a pending public key upload and retry if needed.
  /// 
  /// Call this after login to retry any failed uploads.
  /// Returns true if upload succeeded or no pending upload.
  static Future<bool> retryPendingPublicKeyUpload(User user) async {
    debugPrint('[KEY_UPLOAD] Checking for pending uploads...');
    
    try {
      // Check if there's a pending upload flag
      final pending = await _storage.read(key: _publicKeyPendingKey);
      if (pending != 'true') {
        debugPrint('[KEY_STATUS] No pending upload');
        return true;
      }
      
      debugPrint('[KEY_STATUS] Found pending upload flag');
      
      // Try to get the cached public key
      final cachedKey = await _getCachedPublicKey();
      if (cachedKey == null) {
        debugPrint('[KEY_UPLOAD] No cached public key to upload');
        // Clear the pending flag since we can't retry
        await _storage.delete(key: _publicKeyPendingKey);
        return false;
      }
      
      // Validate cached key has required fields
      final modulus = cachedKey['modulus'];
      final exponent = cachedKey['exponent'];
      final keyVersion = cachedKey['keyVersion'];
      
      if (modulus == null || exponent == null) {
        debugPrint('[KEY_UPLOAD] Cached key missing modulus or exponent');
        await _storage.delete(key: _publicKeyPendingKey);
        return false;
      }
      
      // Retry the upload
      debugPrint('[KEY_UPLOAD] Retrying upload for cached key...');
      try {
        await _firestore.collection('users').doc(user.uid).set({
          'publicKey': {
            'n': modulus,
            'e': exponent,
          },
          'publicKeyVersion': keyVersion ?? 'legacy',
          'keyUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        
        debugPrint('[KEY_UPLOAD] SUCCESS: Pending upload completed');
        debugPrint('[FIRESTORE_RULES] Write succeeded on retry');
        
        // Clear pending flag
        await _storage.delete(key: _publicKeyPendingKey);
        
        // Update session state with safe key version
        final versionStr = keyVersion ?? 'legacy';
        DeviceTrustStateManager.markKeyUploaded(versionStr);
        
        return true;
      } on FirebaseException catch (e) {
        debugPrint('[KEY_UPLOAD] FAILED on retry: ${e.code}');
        debugPrint('[FIRESTORE_RULES] Retry failed: ${e.message}');
        return false;
      }
    } catch (e) {
      debugPrint('[KEY_UPLOAD] ERROR checking pending: $e');
      return false;
    }
  }

  /// Check the current key upload status.
  /// 
  /// Returns one of: 'missing', 'pending', 'uploaded'
  static Future<String> checkKeyUploadStatus() async {
    // Check if we have a local private key
    final privateKey = await _storage.read(key: 'private_key');
    if (privateKey == null) {
      debugPrint('[KEY_STATUS] Status: MISSING - No local private key');
      return 'missing';
    }
    
    // Check if there's a pending upload
    final pending = await _storage.read(key: _publicKeyPendingKey);
    if (pending == 'true') {
      debugPrint('[KEY_STATUS] Status: PENDING - Upload failed previously');
      return 'pending';
    }
    
    // Check if we have a cached public key
    final cachedKey = await _getCachedPublicKey();
    if (cachedKey != null) {
      debugPrint('[KEY_STATUS] Status: UPLOADED - Key cached locally');
      return 'uploaded';
    }
    
    debugPrint('[KEY_STATUS] Status: PENDING - Key exists but not cached');
    return 'pending';
  }
}

/// Extension for state checks
extension EncryptionStartupStateExtension on EncryptionStartupState {
  bool get isBlockingUI =>
      this == EncryptionStartupState.restoringFromBackup ||
      this == EncryptionStartupState.generatingKeys;

  bool get isReady =>
      this == EncryptionStartupState.ready ||
      this == EncryptionStartupState.readyWithWarnings;
}
