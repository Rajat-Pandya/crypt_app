import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'session_lifecycle_manager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';

import '../utils/rsa_helper.dart';
import '../utils/input_validator.dart';
import '../main.dart';
import '../screens/device_approval_screen.dart';
import 'hmac_key_service.dart';
import 'key_backup_service.dart';
import 'game_service.dart';
import 'multiplayer_service.dart';
import 'encryption_startup_service.dart';
import 'device_service.dart';
import 'device_encryption_service.dart';


enum KeyStatus { synced, mismatch, regenerated }

// Startup state machine for encryption setup
enum EncryptionStartupState {
  idle,              // App just started, no user
  authenticating,    // Firebase auth in progress (login/register)
  restoringKeys,    // Restoring keys from backup (PBKDF2)
  verifyingKeys,    // Verifying keys against Firestore
  syncing,          // Syncing public key to Firestore
  ready,            // Encryption ready, can navigate
  failed,           // Setup failed, need logout
}

// Global state for tracking encryption startup progress
class EncryptionStartupManager {
  static EncryptionStartupState state = EncryptionStartupState.idle;
  static String? _currentUserId;
  static bool _loginComplete = false;
  
  static String? get currentUserId => _currentUserId;
  static bool get isReady => state == EncryptionStartupState.ready;
  static bool get isFailed => state == EncryptionStartupState.failed;
  static bool get loginComplete => _loginComplete;
  static bool get isRestoring => state == EncryptionStartupState.restoringKeys;
  static bool get isVerifying => state == EncryptionStartupState.verifyingKeys;
  
  static void setAuthenticating(String? userId) {
    _currentUserId = userId;
    _loginComplete = false;
    state = EncryptionStartupState.authenticating;
  }
  
  static void setRestoringKeys() {
    state = EncryptionStartupState.restoringKeys;
  }
  
  static void setVerifyingKeys() {
    state = EncryptionStartupState.verifyingKeys;
  }
  
  static void setSyncing() {
    state = EncryptionStartupState.syncing;
  }
  
  static void setReady() {
    state = EncryptionStartupState.ready;
    _loginComplete = true;
  }
  
  static void setFailed() {
    state = EncryptionStartupState.failed;
    _loginComplete = true;  // Mark login complete so we don't hang
  }
  
  static void reset() {
    state = EncryptionStartupState.idle;
    _currentUserId = null;
    _loginComplete = false;
  }
  
  // Check if we should wait for encryption setup
  static bool shouldWaitForEncryption() {
    // Don't wait if login not started or already complete/failed
    if (state == EncryptionStartupState.idle ||
        state == EncryptionStartupState.ready ||
        state == EncryptionStartupState.failed) {
      return false;
    }
    // Wait if in any setup phase
    return true;
  }
}

class KeyMismatchDetail {
  final Map<String, String> remotePublicKey;
  final Map<String, String> localPublicKey;

  const KeyMismatchDetail({
    required this.remotePublicKey,
    required this.localPublicKey,
  });
}

class AuthService {
  static final FirebaseAuth auth = FirebaseAuth.instance;
  static final storage = const FlutterSecureStorage();
  static final _firestore = FirebaseFirestore.instance;

  // Public key metadata cache for faster login
  static const String _verifiedPublicKeyKey = 'verified_public_key';
  static const Duration _keyCacheTTL = Duration(days: 7);

static bool loginInProgress = false;
  static const _publicKeyPendingKey = 'public_key_upload_pending';
  static const publicKeyPendingKey =
      _publicKeyPendingKey; // public alias for main.dart

  // Blocker to prevent duplicate setupEncryption calls during same login
  static final Map<String, Future<({KeyStatus status, KeyMismatchDetail? mismatchDetail})>> _setupEncryptionInProgress = {};

  // User data cache to reduce Firestore reads
  static final Map<String, _CachedUserData> _userDataCache = {};
  static const Duration _userDataCacheTTL = Duration(minutes: 5);

  static void _dbg(String message) {
    assert(() {
      debugPrint('[AuthService] $message');
      return true;
    }());
  }

  // ==========================================================================
  // USER DATA CACHE (Reduces Firestore Reads)
  // ==========================================================================

  /// Checks user existence from cache first, then Firestore
  static Future<bool> _checkUserExists(String uid) async {
    final cached = _userDataCache[uid];
    if (cached != null && cached.isValid) {
      debugPrint('[AuthService] _checkUserExists: cache hit - uid: $uid');
      return cached.exists;
    }
    
    debugPrint('[AuthService] _checkUserExists: cache miss - uid: $uid');
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      final exists = doc.exists;
      _userDataCache[uid] = _CachedUserData(
        exists: exists,
        name: doc.data()?['name'] as String?,
        cachedAt: DateTime.now(),
      );
      return exists;
    } catch (e) {
      debugPrint('[AuthService] _checkUserExists: error - $e');
      return false;
    }
  }

  /// Gets user name from cache or Firestore
  static Future<String?> _getUserName(String uid) async {
    final cached = _userDataCache[uid];
    if (cached != null && cached.isValid) {
      debugPrint('[AuthService] _getUserName: cache hit - uid: $uid');
      return cached.name;
    }
    
    debugPrint('[AuthService] _getUserName: cache miss - uid: $uid');
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      final name = doc.data()?['name'] as String?;
      _userDataCache[uid] = _CachedUserData(
        exists: doc.exists,
        name: name,
        cachedAt: DateTime.now(),
      );
      return name;
    } catch (e) {
      debugPrint('[AuthService] _getUserName: error - $e');
      return null;
    }
  }

  /// Clears user data cache (call on logout)
  static void clearUserDataCache() {
    _userDataCache.clear();
    debugPrint('[AuthService] clearUserDataCache: cleared');
  }

  // ==========================================================================
  // PUBLIC KEY CACHE (Verified with TTL)
  // ==========================================================================

  // ── Public Key Metadata Cache ───────────────────────────────────────────

  static Future<Map<String, dynamic>?> _getCachedPublicKey() async {
    debugPrint('[AuthService] _getCachedPublicKey: START');
    try {
      final cached = await storage.read(key: _verifiedPublicKeyKey);
      if (cached == null) {
        debugPrint('[AuthService] _getCachedPublicKey: no cached key found');
        debugPrint('[AuthService] _getCachedPublicKey: END');
        return null;
      }

      final data = jsonDecode(cached) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(data['cachedAt'] as String);

      if (DateTime.now().difference(cachedAt) > _keyCacheTTL) {
        debugPrint('[AuthService] _getCachedPublicKey: cache expired');
        await storage.delete(key: _verifiedPublicKeyKey);
        debugPrint('[AuthService] _getCachedPublicKey: END');
        return null;
      }

      debugPrint('[AuthService] _getCachedPublicKey: SUCCESS - cache valid');
      debugPrint('[AuthService] _getCachedPublicKey: END');
      return data;
    } catch (e) {
      debugPrint('[AuthService] _getCachedPublicKey: ERROR - ${e.runtimeType}: $e');
      debugPrint('[AuthService] _getCachedPublicKey: END');
      return null;
    }
  }

  static Future<void> _cachePublicKey({
    required String modulus,
    required String exponent,
    required String keyVersion,
  }) async {
    debugPrint('[AuthService] _cachePublicKey: START - keyVersion: $keyVersion');
    try {
      final data = {
        'modulus': modulus,
        'exponent': exponent,
        'keyVersion': keyVersion,
        'cachedAt': DateTime.now().toIso8601String(),
      };
      await storage.write(key: _verifiedPublicKeyKey, value: jsonEncode(data));
      debugPrint('[AuthService] _cachePublicKey: SUCCESS - key cached');
    } catch (e) {
      debugPrint('[AuthService] _cachePublicKey: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[AuthService] _cachePublicKey: END');
  }

  static Future<void> _clearPublicKeyCache() async {
    debugPrint('[AuthService] _clearPublicKeyCache: START');
    try {
      await storage.delete(key: _verifiedPublicKeyKey);
      debugPrint('[AuthService] _clearPublicKeyCache: SUCCESS - cache cleared');
    } catch (e) {
      debugPrint('[AuthService] _clearPublicKeyCache: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[AuthService] _clearPublicKeyCache: END');
  }

  static Future<void> _validateCachedKeyInBackground(
    String uid,
    String localModulus,
  ) async {
    debugPrint('[AuthService] _validateCachedKeyInBackground: START - uid: $uid');
    // Background revalidation - don't block login
    Future.microtask(() async {
      try {
        final doc = await _firestore.collection('users').doc(uid).get();
        if (!doc.exists) {
          debugPrint('[AuthService] _validateCachedKeyInBackground: user doc not found');
          return;
        }

        final firestoreKey = doc.data()?['publicKey'];
        if (firestoreKey == null) {
          debugPrint('[AuthService] _validateCachedKeyInBackground: no public key in Firestore');
          return;
        }

        final firestoreModulus = firestoreKey['n']?.toString();
        if (firestoreModulus != localModulus) {
          debugPrint('[AuthService] _validateCachedKeyInBackground: mismatch detected');
          await _clearPublicKeyCache();
        } else {
          debugPrint('[AuthService] _validateCachedKeyInBackground: key still valid');
        }
      } catch (e) {
        debugPrint('[AuthService] _validateCachedKeyInBackground: error - $e');
      }
    });
    debugPrint('[AuthService] _validateCachedKeyInBackground: END - background task scheduled');
  }

  static Future<({KeyStatus status, KeyMismatchDetail? mismatchDetail})>
  setupEncryption(User user, {String? password}) async {
    // Block duplicate calls during same login
    if (_setupEncryptionInProgress.containsKey(user.uid)) {
      debugPrint('[AuthService] setupEncryption: already in progress for ${user.uid}, waiting...');
      return await _setupEncryptionInProgress[user.uid]!;
    }
    
    debugPrint('[AuthService] setupEncryption: START - uid: ${user.uid}, hasPassword: ${password != null}');
    EncryptionStartupManager.setVerifyingKeys();  // Start in verifying state
    
    final existingKeyStrCheck = await storage.read(key: 'private_key');
    if (existingKeyStrCheck == null && password != null) {
      debugPrint('[AuthService] setupEncryption: no local key found, attempting restore from backup');
      EncryptionStartupManager.setRestoringKeys();  // Set to restoring when doing PBKDF2
      
      final result = await KeyBackupService.restorePrivateKey(
        user: user,
        password: password,
      );
      
      EncryptionStartupManager.setVerifyingKeys();  // Back to verifying after restore
      
      switch (result) {
        case KeyRestoreResult.success:
          debugPrint('[AuthService] setupEncryption: key restored from backup');
          break;
        case KeyRestoreResult.noBackup:
          debugPrint('[AuthService] setupEncryption: no backup found, will generate fresh key');
          break;
        case KeyRestoreResult.wrongPassword:
          debugPrint('[AuthService] setupEncryption: wrong password - aborting to prevent data loss');
          EncryptionStartupManager.setFailed();
          debugPrint('[AuthService] setupEncryption: END');
          return (status: KeyStatus.mismatch, mismatchDetail: null);
      }
    }

    final existingKeyStr = await storage.read(key: 'private_key');

    if (existingKeyStr != null) {
      debugPrint('[AuthService] setupEncryption: existing key found, checking format');
      final keyData = jsonDecode(existingKeyStr) as Map<String, dynamic>;
      final hasPublicExponent = keyData['e'] != null;

      if (!hasPublicExponent) {
        debugPrint('[AuthService] setupEncryption: old key format detected, regenerating');
        await storage.delete(key: 'private_key');
      } else {
        // Check cached key metadata first (7-day TTL)
        debugPrint('[AuthService] setupEncryption: checking cached key');
        final cachedKey = await _getCachedPublicKey();
        final localModulus = keyData['n'].toString();
        final localVersion = _keyVersion(localModulus);

        if (cachedKey != null && cachedKey['modulus'] == localModulus) {
          debugPrint('[AuthService] setupEncryption: using cached public key (TTL valid)');
          await storage.write(key: 'encryption_setup_done', value: 'true');
          
          // Background validation - don't block login
          _validateCachedKeyInBackground(user.uid, localModulus);
          
          EncryptionStartupManager.state = EncryptionStartupState.ready;
          EncryptionStartupManager;
          _setupEncryptionInProgress.remove(user.uid);
          debugPrint('[AuthService] setupEncryption: END');
          return (status: KeyStatus.synced, mismatchDetail: null);
        }

        late final DocumentSnapshot<Map<String, dynamic>> doc;
        try {
          debugPrint('[AuthService] setupEncryption: fetching user document from Firestore');
          doc = await _firestore.collection('users').doc(user.uid).get();
        } on FirebaseException catch (e) {
          debugPrint('[AuthService] setupEncryption: Firestore key check failed (${e.code}), assuming synced');
          await storage.write(key: 'encryption_setup_done', value: 'true');
          
          // Cache key even on Firestore failure for fast next login
          final localModulus = keyData['n'].toString();
          await _cachePublicKey(
            modulus: localModulus,
            exponent: keyData['e'].toString(),
            keyVersion: _keyVersion(localModulus),
          );
          
          EncryptionStartupManager.state = EncryptionStartupState.ready;
          EncryptionStartupManager;
          _setupEncryptionInProgress.remove(user.uid);
          debugPrint('[AuthService] setupEncryption: END');
          return (status: KeyStatus.synced, mismatchDetail: null);
        }
        final firestoreKey = doc.data()?['publicKey'];

        final hasValidPublicKey =
            firestoreKey != null &&
            firestoreKey['n'] != null &&
            firestoreKey['e'] != null;

        if (!hasValidPublicKey) {
          debugPrint('[AuthService] setupEncryption: public key missing from Firestore, re-uploading');

          await _firestore.collection('users').doc(user.uid).set({
            'publicKey': {'n': keyData['n'], 'e': keyData['e']},
            'publicKeyVersion': _keyVersion(keyData['n'] as String),
          }, SetOptions(merge: true));

          debugPrint('[AuthService] setupEncryption: public key re-uploaded');
          await storage.write(key: 'encryption_setup_done', value: 'true');
          
          // Cache public key immediately after re-upload
          final localModulus = keyData['n'].toString();
          await _cachePublicKey(
            modulus: localModulus,
            exponent: keyData['e'].toString(),
            keyVersion: _keyVersion(localModulus),
          );
          
          EncryptionStartupManager.state = EncryptionStartupState.ready;
          EncryptionStartupManager;
          _setupEncryptionInProgress.remove(user.uid);
          debugPrint('[AuthService] setupEncryption: END');
          return (status: KeyStatus.synced, mismatchDetail: null);
        }

        final firestoreModulus = (firestoreKey['n'] as String);

        if (localModulus != firestoreModulus) {
          debugPrint('[AuthService] setupEncryption: key mismatch detected');
          EncryptionStartupManager.state = EncryptionStartupState.failed;
          EncryptionStartupManager;
          _setupEncryptionInProgress.remove(user.uid);
          debugPrint('[AuthService] setupEncryption: END');
          return (
            status: KeyStatus.mismatch,
            mismatchDetail: KeyMismatchDetail(
              remotePublicKey: {
                'n': firestoreKey['n'] as String,
                'e': firestoreKey['e'] as String,
              },
              localPublicKey: {
                'n': keyData['n'] as String,
                'e': keyData['e'] as String,
              },
            ),
          );
        }

        debugPrint('[AuthService] setupEncryption: encryption keys verified and in sync');
        await storage.write(key: 'encryption_setup_done', value: 'true');
        
        // Cache verified public key metadata (7-day TTL)
        await _cachePublicKey(
          modulus: localModulus,
          exponent: keyData['e'].toString(),
          keyVersion: localVersion,
        );
        
        EncryptionStartupManager.state = EncryptionStartupState.ready;
        EncryptionStartupManager;
        _setupEncryptionInProgress.remove(user.uid);
        debugPrint('[AuthService] setupEncryption: END');
        return (status: KeyStatus.synced, mismatchDetail: null);
      }
    }

    debugPrint('[AuthService] setupEncryption: generating new RSA key pair');

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

    // Store private key first - this should always succeed
    debugPrint('[AuthService] setupEncryption: storing private key');
    await storage.write(key: 'private_key', value: privateKeyData);
    debugPrint('[AuthService] setupEncryption: private key stored');

    // Try to upload public key to Firestore - may fail on emulator due to App Check
    try {
      debugPrint('[AuthService] setupEncryption: uploading public key to Firestore');
      await _firestore.collection('users').doc(user.uid).set({
        'publicKey': {'n': nStr, 'e': eStr},
        'publicKeyVersion': _keyVersion(nStr),
      }, SetOptions(merge: true));
      debugPrint('[AuthService] setupEncryption: public key uploaded successfully');
    } on FirebaseException catch (e) {
      debugPrint('[AuthService] setupEncryption: public key upload failed (${e.code}), marked as pending');
      await storage.write(key: _publicKeyPendingKey, value: 'true');
    }

    // Try to backup encrypted key - may fail due to App Check or network
    if (password != null) {
      try {
        debugPrint('[AuthService] setupEncryption: backing up private key');
        await KeyBackupService.backupPrivateKey(
          user: user,
          privateKeyJson: privateKeyData,
          password: password,
        );
        debugPrint('[AuthService] setupEncryption: private key backed up');
      } catch (e) {
        debugPrint('[AuthService] setupEncryption: key backup failed - ${e.runtimeType}, marked as pending');
        await storage.write(
          key: KeyBackupService.backupPendingKey,
          value: 'true',
        );
      }
    } else {
      debugPrint('[AuthService] setupEncryption: no password provided, skipping key backup');
      await storage.write(
        key: KeyBackupService.backupPendingKey,
        value: 'true',
      );
    }

    debugPrint('[AuthService] setupEncryption: RSA key pair generated and saved');
    await storage.write(key: 'encryption_setup_done', value: 'true');
    
    // Immediately cache public key for fast future logins
    await _cachePublicKey(
      modulus: nStr,
      exponent: eStr,
      keyVersion: _keyVersion(nStr),
    );
    
    EncryptionStartupManager.state = EncryptionStartupState.ready;
    EncryptionStartupManager;
    _setupEncryptionInProgress.remove(user.uid);
    debugPrint('[AuthService] setupEncryption: END');
    return (status: KeyStatus.regenerated, mismatchDetail: null);
  }

  // Helper to ensure cleanup happens on all return paths
  static Future<({KeyStatus status, KeyMismatchDetail? mismatchDetail})> _completeSetupEncryption(
    User user,
    ({KeyStatus status, KeyMismatchDetail? mismatchDetail}) result,
  ) async {
    if (result.status == KeyStatus.synced) {
      EncryptionStartupManager.state = EncryptionStartupState.ready;
    } else if (result.status == KeyStatus.mismatch) {
      EncryptionStartupManager.state = EncryptionStartupState.failed;
    }
    EncryptionStartupManager;
    _setupEncryptionInProgress.remove(user.uid);
    return result;
  }

  static Future<void> resolveKeyMismatch({
    required User user,
    required KeyMismatchDetail detail,
    required bool keepLocal,
    String? password,
  }) async {
    debugPrint('[AuthService] resolveKeyMismatch: START - uid: ${user.uid}, keepLocal: $keepLocal');
    if (keepLocal) {
      debugPrint('[AuthService] resolveKeyMismatch: user chose local key, updating Firestore');

      await _firestore.collection('users').doc(user.uid).set({
        'publicKey': detail.localPublicKey,
        'publicKeyVersion': _keyVersion(detail.localPublicKey['n']!),
      }, SetOptions(merge: true));

      await storage.write(key: 'encryption_setup_done', value: 'true');
      debugPrint('[AuthService] resolveKeyMismatch: encryption_setup_done flag set after local key acceptance');
    } else {
      debugPrint('[AuthService] resolveKeyMismatch: user chose remote key, deleting local key');
      await storage.delete(key: 'private_key');
      await storage.delete(key: KeyBackupService.backupConfirmedKey);

      if (password != null) {
        debugPrint('[AuthService] resolveKeyMismatch: attempting immediate key restore');
        final result = await KeyBackupService.restorePrivateKey(
          user: user,
          password: password,
        );
        if (result == KeyRestoreResult.success) {
          debugPrint('[AuthService] resolveKeyMismatch: key restored immediately');
          await storage.write(key: 'encryption_setup_done', value: 'true');
          debugPrint('[AuthService] resolveKeyMismatch: END');
          return;
        }
        debugPrint('[AuthService] resolveKeyMismatch: immediate restore failed');
      }

      await storage.delete(key: 'encryption_setup_done');
      debugPrint('[AuthService] resolveKeyMismatch: cleared encryption_setup_done flag after key deletion');
    }
    debugPrint('[AuthService] resolveKeyMismatch: END');
  }

  static String _keyVersion(String modulus) {
    return modulus.substring(0, 8);
  }

  static Future<void> saveUserData(
    User user,
    String email, {
    bool isOnline = true,
    bool setName = true,
  }) async {
    debugPrint('[AuthService] saveUserData: START - uid: ${user.uid}, email: $email, isOnline: $isOnline');
    if (auth.currentUser == null) {
      debugPrint('[AuthService] saveUserData: aborted - no current user');
      debugPrint('[AuthService] saveUserData: END');
      return;
    }

    if (auth.currentUser!.uid != user.uid) {
      debugPrint('[AuthService] saveUserData: aborted - uid mismatch');
      debugPrint('[AuthService] saveUserData: END');
      return;
    }

    final playerId = OneSignal.User.pushSubscription.id;
    debugPrint('[AuthService] saveUserData: OneSignal playerId: $playerId');

    try {
      // OPTIMIZATION: Use cache to avoid extra Firestore read
      String? existingName;
      if (setName) {
        existingName = await _getUserName(user.uid);
        debugPrint('[AuthService] saveUserData: existingName from cache: $existingName');
      }

      debugPrint('[AuthService] saveUserData: saving user data to Firestore');
      await _firestore.collection('users').doc(user.uid).set({
        'email': email.trim().toLowerCase(),
        if (setName && existingName == null) 'name': email.split('@')[0],
        'uid': user.uid,
        'oneSignalPlayerId': playerId,
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': isOnline,
      }, SetOptions(merge: true));

      // Update cache after successful write
      _userDataCache[user.uid] = _CachedUserData(
        exists: true,
        name: setName && existingName == null ? email.split('@')[0] : existingName,
        cachedAt: DateTime.now(),
      );

      debugPrint('[AuthService] saveUserData: SUCCESS - user data saved');
    } catch (e) {
      debugPrint('[AuthService] saveUserData: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[AuthService] saveUserData: END');
  }

  static Future<void> setUserOffline(User user) async {
    debugPrint('[AuthService] setUserOffline: START - uid: ${user.uid}');
    try {
      await _firestore.collection('users').doc(user.uid).set({
        'isOnline': false,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      debugPrint('[AuthService] setUserOffline: SUCCESS - user marked offline');
    } catch (e) {
      debugPrint('[AuthService] setUserOffline: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[AuthService] setUserOffline: END');
  }

  static Future<bool> isEmailVerified() async {
    debugPrint('[AuthService] isEmailVerified: START');
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[AuthService] isEmailVerified: no user, returning false');
      debugPrint('[AuthService] isEmailVerified: END');
      return false;
    }

    await user.reload();
    final refreshedUser = auth.currentUser;

    final verified = refreshedUser?.emailVerified ?? false;
    debugPrint('[AuthService] isEmailVerified: SUCCESS - emailVerified: $verified');
    debugPrint('[AuthService] isEmailVerified: END');
    return verified;
  }

  static Future<void> sendVerificationEmail() async {
    debugPrint('[AuthService] sendVerificationEmail: START');
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[AuthService] sendVerificationEmail: ERROR - no user logged in');
      throw Exception('No user logged in');
    }

    try {
      debugPrint('[AuthService] sendVerificationEmail: sending verification email');
      await user.sendEmailVerification();
      debugPrint('[AuthService] sendVerificationEmail: SUCCESS - email sent');
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      debugPrint('[AuthService] sendVerificationEmail: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatService] sendVerificationEmail: END');
  }

  static Future<User?> register(String email, String password) async {
    debugPrint('[AuthService] register: START - email: $email');
    final cleanEmail = email.trim();
    final cleanPassword = password.trim();

    final emailErr = InputValidator.validateEmail(cleanEmail);
    if (emailErr != null) {
      debugPrint('[AuthService] register: ERROR - invalid email: $emailErr');
      throw FirebaseAuthException(code: 'invalid-email');
    }

    if (cleanPassword.length < 6) {
      debugPrint('[AuthService] register: ERROR - weak password');
      throw FirebaseAuthException(code: 'weak-password');
    }

    debugPrint('[AuthService] register: starting user creation');

    final result = await auth.createUserWithEmailAndPassword(
      email: cleanEmail,
      password: cleanPassword,
    );

    final user = result.user!;
    debugPrint('[AuthService] register: user created - uid: ${user.uid}');

    final (:status, :mismatchDetail) = await setupEncryption(
      user,
      password: cleanPassword,
    );
    debugPrint('[AuthService] register: encryption setup status: ${status.name}');

    await storage.write(key: 'encryption_setup_done', value: 'true');

    try {
      await saveUserData(user, cleanEmail, isOnline: false);
    } catch (e) {
      debugPrint('[AuthService] register: saveUserData failed - ${e.runtimeType} - non-fatal');
    }

    try {
      await sendVerificationEmail();
    } catch (e) {
      debugPrint('[AuthService] register: verification email failed - ${e.runtimeType}');
    }

    debugPrint('[AuthService] register: SUCCESS - registration complete');
    debugPrint('[AuthService] register: END');
    return user;
  }

  /// Non-blocking login that returns immediately after Firebase auth.
  /// 
  /// CRITICAL: This method does NOT wait for encryption setup.
  /// Encryption startup happens in background via EncryptionStartupService.
  /// UI navigates to app shell immediately.
  static Future<User?> login(
    String email,
    String password,
  ) async {
    debugPrint('[AUTH] login: START - email: $email');
    loginInProgress = true;

    try {
      final cleanEmail = email.trim();
      final cleanPassword = password.trim();

      // Validate inputs
      final emailErr = InputValidator.validateEmail(cleanEmail);
      if (emailErr != null) {
        debugPrint('[AUTH] login: ERROR - invalid email');
        throw FirebaseAuthException(code: 'invalid-email');
      }

      if (cleanPassword.isEmpty) {
        debugPrint('[AUTH] login: ERROR - empty password');
        throw FirebaseAuthException(code: 'wrong-password');
      }

      // Authenticate with Firebase
      debugPrint('[AUTH] login: authenticating with Firebase...');
      final result = await auth.signInWithEmailAndPassword(
        email: cleanEmail,
        password: cleanPassword,
      );

      final user = result.user!;
      await user.reload();
      final refreshedUser = auth.currentUser!;

      debugPrint('[AUTH] login: authenticated - uid: ${refreshedUser.uid}, verified: ${refreshedUser.emailVerified}');

      // If email not verified, return immediately (don't start encryption)
      if (!refreshedUser.emailVerified) {
        debugPrint('[AUTH] login: email not verified, returning for verification');
        loginInProgress = false;
        return refreshedUser;
      }

      // ============================================
      // NON-BLOCKING: Start encryption in background
      // ============================================
      // DO NOT await this - let it run in background
      // UI navigates to app shell immediately
      // ============================================
      Future.microtask(() async {
        debugPrint('[AUTH] login: starting background encryption startup');

        // Phase 1: Update user presence (immediate, fast)
        try {
          final userExists = await _checkUserExists(refreshedUser.uid);
          if (!userExists) {
            // New user - set name from email
            await saveUserData(refreshedUser, cleanEmail, isOnline: true, setName: true);
          } else {
            await _firestore.collection('users').doc(refreshedUser.uid).set({
              'isOnline': true,
              'lastSeen': FieldValue.serverTimestamp(),
              'emailVerified': true,
            }, SetOptions(merge: true));
          }
          debugPrint('[AUTH] login: user presence updated');
        } catch (e) {
          debugPrint('[AUTH] login: presence update failed (non-fatal): $e');
        }

        // Phase 2: Device registration (slight delay to prioritize UI)
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          await DeviceService.registerDevice(user: refreshedUser);
          debugPrint('[DEVICE] Device registered successfully');
        } catch (e) {
          debugPrint('[DEVICE] Device registration failed (non-fatal): $e');
        }

        // Phase 3: Trust initialization
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          final trustState = await DeviceService.completeDeviceRegistration(refreshedUser);
          debugPrint('[TRUST] Device trust status: ${trustState.status.name}');

          if (!trustState.isTrusted) {
            // New device - navigate to approval screen
            debugPrint('[TRUST] Device pending approval - navigating to approval screen');
            navigatorKey.currentState?.pushReplacement(
              MaterialPageRoute(builder: (_) => const DeviceApprovalScreen()),
            );
            return;
          }
        } catch (e) {
          debugPrint('[TRUST] Device trust initialization failed (non-fatal): $e');
        }

        // Phase 4: Start encryption services
        // This runs PBKDF2, RSA generation, etc. without blocking UI
        debugPrint('[ENC] login: triggering background encryption startup');

        // Start encryption service
        EncryptionStartupService.initialize(
          user: refreshedUser,
          password: cleanPassword,
        );

        // Phase 5: Initialize per-device encryption (with delay)
        await Future.delayed(const Duration(milliseconds: 200));
        try {
          await DeviceEncryptionService.initialize(refreshedUser);
          debugPrint('[E2EE] Device encryption initialized');
        } catch (e) {
          debugPrint('[E2EE] Device encryption init failed (non-fatal): $e');
        }

        // Phase 6: Session recovery (lowest priority)
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          await SessionLifecycleManager.initializeSession(refreshedUser);
          debugPrint('[SESSION] Session initialized');
        } catch (e) {
          debugPrint('[SESSION] Session init failed (non-fatal): $e');
        }
      });

      debugPrint('[NAV] login: SUCCESS - returning user immediately');
      loginInProgress = false;
      return refreshedUser;

    } on FirebaseAuthException {
      rethrow;
    } catch (e) {
      debugPrint('[AUTH] login: ERROR - ${e.runtimeType}: $e');
      throw FirebaseAuthException(
        code: 'unknown',
        message: 'Login failed: ${e.toString()}',
      );
    } finally {
      loginInProgress = false;
      debugPrint('[AUTH] login: END');
    }
  }

  static Future<void> resendVerificationEmail() => sendVerificationEmail();

  static Future<void> logout(BuildContext context) async {
    debugPrint('[AuthService] logout: START');
    EncryptionStartupManager.reset();
    SessionLifecycleManager.terminateSession();
    // Clear all game streams including MultiplayerService-owned (logout = full cleanup)
    GameService.clearAllStreamsForce();
    // Dispose MultiplayerService
    await MultiplayerService().dispose();
    
    // Clear session-level caches
    KeyBackupService.clearDerivedKeyCache();
    
    // Clear HMAC keys from memory (security: remove key material)
    HmacKeyService.clear();
    debugPrint('[AuthService] logout: HMAC keys cleared');

    // Clear device encryption from memory (keys remain in secure storage)
    DeviceEncryptionService.reset();
    debugPrint('[AuthService] logout: Device encryption reset');
    
    // Clear device trust, session recovery, and validation
    await DeviceService.resetOnLogout();
    debugPrint('[AuthService] logout: Device trust and session services reset');
    
    // Clear user data cache (privacy: remove user metadata)
    clearUserDataCache();
    debugPrint('[AuthService] logout: user data cache cleared');

    final user = auth.currentUser;
    if (user != null) {
      debugPrint('[AuthService] logout: setting user offline - uid: ${user.uid}');
      await setUserOffline(user);
    }

    await storage.delete(key: 'encryption_setup_done');
    debugPrint('[AuthService] logout: encryption_setup_done flag cleared');

    await auth.signOut();
    debugPrint('[AuthService] logout: SUCCESS - user signed out');
    debugPrint('[AuthService] logout: END');
  }

  static Future<void> retryPublicKeyUpload(User user) async {
    debugPrint('[AuthService] retryPublicKeyUpload: START - uid: ${user.uid}');
    try {
      final keyStr = await storage.read(key: 'private_key');
      if (keyStr == null) {
        debugPrint('[AuthService] retryPublicKeyUpload: no private key found');
        debugPrint('[AuthService] retryPublicKeyUpload: END');
        throw Exception('No local private key found. Please re-login.');
      }
      final kd = jsonDecode(keyStr) as Map<String, dynamic>;
      
      // Check if we have the required fields
      if (kd['n'] == null || kd['e'] == null) {
        debugPrint('[AuthService] retryPublicKeyUpload: ERROR - missing key components');
        throw Exception('Invalid key format. Please re-login.');
      }
      
      // First check if user doc exists
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) {
        debugPrint('[AuthService] retryPublicKeyUpload: user document does not exist, creating...');
        // Create the user document first
        await _firestore.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': user.email,
          'createdAt': FieldValue.serverTimestamp(),
          'publicKey': {'n': kd['n'], 'e': kd['e']},
          'publicKeyVersion': _keyVersion(kd['n'] as String),
        });
      } else {
        // Update existing document
        await _firestore.collection('users').doc(user.uid).set({
          'publicKey': {'n': kd['n'], 'e': kd['e']},
          'publicKeyVersion': _keyVersion(kd['n'] as String),
        }, SetOptions(merge: true));
      }
      
      await storage.delete(key: _publicKeyPendingKey);
      debugPrint('[AuthService] retryPublicKeyUpload: SUCCESS - public key uploaded');
    } on FirebaseException catch (e) {
      debugPrint('[AuthService] retryPublicKeyUpload: FIREBASE ERROR - ${e.code}: ${e.message}');
      throw Exception('Failed to upload public key: ${e.message}');
    } catch (e, stackTrace) {
      debugPrint('[AuthService] retryPublicKeyUpload: ERROR - ${e.runtimeType}: $e');
      debugPrint('[AuthService] Stack trace: $stackTrace');
      rethrow;
    }
    debugPrint('[AuthService] retryPublicKeyUpload: END');
  }

  static Future<String?> getPrivateKey() async {
    debugPrint('[AuthService] getPrivateKey: START');
    try {
      final key = await storage.read(key: 'private_key');
      if (key != null) {
        debugPrint('[AuthService] getPrivateKey: SUCCESS - key retrieved');
      } else {
        debugPrint('[AuthService] getPrivateKey: no key found');
      }
      debugPrint('[AuthService] getPrivateKey: END');
      return key;
    } catch (e) {
      debugPrint('[AuthService] getPrivateKey: ERROR - ${e.runtimeType}: $e');
      debugPrint('[AuthService] getPrivateKey: END');
      return null;
    }
  }

  /// Archive of previous private keys for decrypting old messages.
  /// Key: keyVersion, Value: private key JSON
  static const String _archivedKeysPrefix = 'archived_private_key_';
  
  /// Maximum number of archived keys to keep
  static const int _maxArchivedKeys = 3;

  /// Rotates encryption keys for the current user
  /// 
  /// This generates new RSA keys and uploads the new public key to Firestore.
  /// The old private key is archived so historical messages can still be decrypted.
  static Future<bool> rotateKeys(BuildContext context) async {
    debugPrint('[AuthService] rotateKeys: START');
    
    final user = auth.currentUser;
    if (user == null) {
      debugPrint('[AuthService] rotateKeys: ERROR - no user logged in');
      debugPrint('[AuthService] rotateKeys: END');
      return false;
    }
    
    try {
      // First, archive the current private key if it exists
      debugPrint('[AuthService] rotateKeys: checking for existing key to archive');
      final existingKeyStr = await storage.read(key: 'private_key');
      final existingVersion = await storage.read(key: 'public_key_version');
      
      if (existingKeyStr != null && existingVersion != null) {
        debugPrint('[AuthService] rotateKeys: archiving existing key version $existingVersion');
        await storage.write(
          key: '$_archivedKeysPrefix$existingVersion',
          value: existingKeyStr,
        );
        
        // Clean up old archived keys (keep only last _maxArchivedKeys)
        await _cleanupArchivedKeys();
      }
      
      debugPrint('[AuthService] rotateKeys: generating new RSA key pair');
      final newKeys = await RSAHelper.generateKeyPair();
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final privateKeyData = {
        'n': newKeys.privateKey.modulus.toString(),
        'd': newKeys.privateKey.privateExponent.toString(),
        'p': newKeys.privateKey.p.toString(),
        'q': newKeys.privateKey.q.toString(),
      };
      
      debugPrint('[AuthService] rotateKeys: saving keys to secure storage');
      await storage.write(
        key: 'private_key',
        value: jsonEncode(privateKeyData),
      );
      await storage.write(
        key: 'public_key',
        value: jsonEncode({
          'n': newKeys.publicKey.modulus.toString(),
          'e': newKeys.publicKey.exponent.toString(),
        }),
      );
      await storage.write(
        key: 'public_key_version',
        value: timestamp,
      );
      
      debugPrint('[AuthService] rotateKeys: uploading new public key to Firestore');
      await _firestore.collection('users').doc(user.uid).set({
        'publicKey': {
          'n': newKeys.publicKey.modulus.toString(),
          'e': newKeys.publicKey.exponent.toString(),
        },
        'publicKeyVersion': timestamp,
        'keyRotatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      
      debugPrint('[AuthService] rotateKeys: updating cache');
      await _cachePublicKey(
        modulus: newKeys.publicKey.modulus.toString(),
        exponent: newKeys.publicKey.exponent.toString(),
        keyVersion: timestamp,
      );
      
      debugPrint('[AuthService] rotateKeys: SUCCESS - keys rotated, old key archived');
      return true;
    } catch (e) {
      debugPrint('[AuthService] rotateKeys: ERROR - ${e.runtimeType}: $e');
      return false;
    } finally {
      debugPrint('[AuthService] rotateKeys: END');
    }
  }
  
  /// Clean up old archived keys, keeping only the most recent ones
  static Future<void> _cleanupArchivedKeys() async {
    try {
      final allKeys = await storage.readAll();
      final archivedKeys = allKeys.entries
          .where((e) => e.key.startsWith(_archivedKeysPrefix))
          .map((e) => e.key)
          .toList();
      
      if (archivedKeys.length > _maxArchivedKeys) {
        // Sort by key name (which includes timestamp) and delete oldest
        archivedKeys.sort();
        final keysToDelete = archivedKeys.sublist(0, archivedKeys.length - _maxArchivedKeys);
        
        for (final key in keysToDelete) {
          await storage.delete(key: key);
          debugPrint('[AuthService] _cleanupArchivedKeys: deleted old key $key');
        }
      }
    } catch (e) {
      debugPrint('[AuthService] _cleanupArchivedKeys: ERROR - $e');
    }
  }
  
  /// Get a private key for decryption - tries current key first, then archived keys
  /// 
  /// [keyVersion] - The version of the key needed for decryption
  static Future<RSAPrivateKey?> getPrivateKeyForVersion(String? keyVersion) async {
    debugPrint('[AuthService] getPrivateKeyForVersion: START - version=$keyVersion');
    
    try {
      // If no specific version requested, or version matches current, use current key
      final currentVersion = await storage.read(key: 'public_key_version');
      if (keyVersion == null || keyVersion == currentVersion) {
        debugPrint('[AuthService] getPrivateKeyForVersion: using current key');
        final currentKeyStr = await getPrivateKey();
        if (currentKeyStr == null) {
          debugPrint('[AuthService] getPrivateKeyForVersion: current key not found');
          debugPrint('[AuthService] getPrivateKeyForVersion: END');
          return null;
        }
        final data = jsonDecode(currentKeyStr) as Map<String, dynamic>;
        final key = RSAPrivateKey(
          BigInt.parse(data['n'] as String),
          BigInt.parse(data['d'] as String),
          BigInt.parse(data['p'] as String),
          BigInt.parse(data['q'] as String),
        );
        debugPrint('[AuthService] getPrivateKeyForVersion: SUCCESS - using current key');
        debugPrint('[AuthService] getPrivateKeyForVersion: END');
        return key;
      }
      
      // Try to get archived key
      debugPrint('[AuthService] getPrivateKeyForVersion: looking for archived key $keyVersion');
      final archivedKeyStr = await storage.read(key: '$_archivedKeysPrefix$keyVersion');
      
      if (archivedKeyStr != null) {
        final data = jsonDecode(archivedKeyStr) as Map<String, dynamic>;
        final key = RSAPrivateKey(
          BigInt.parse(data['n'] as String),
          BigInt.parse(data['d'] as String),
          BigInt.parse(data['p'] as String),
          BigInt.parse(data['q'] as String),
        );
        debugPrint('[AuthService] getPrivateKeyForVersion: SUCCESS - found archived key');
        debugPrint('[AuthService] getPrivateKeyForVersion: END');
        return key;
      }
      
      debugPrint('[AuthService] getPrivateKeyForVersion: archived key not found');
      debugPrint('[AuthService] getPrivateKeyForVersion: END');
      return null;
    } catch (e) {
      debugPrint('[AuthService] getPrivateKeyForVersion: ERROR - ${e.runtimeType}: $e');
      debugPrint('[AuthService] getPrivateKeyForVersion: END');
      return null;
    }
  }

  /// Sends a password reset email to the given email address.
  /// 
  /// Security: Always returns success even if email doesn't exist to prevent
  /// account enumeration attacks. The actual Firebase error is only logged.
  /// 
  /// Returns: true if request was sent (or would have been sent if email exists)
  /// Returns: false if there's a validation error (invalid email, etc.)
  /// Throws: only for unexpected errors
  static Future<({bool success, String message})> sendPasswordResetEmail(
    String email,
  ) async {
    debugPrint('[RESET] sendPasswordResetEmail: START - email=$email');

    // Validate email format
    final emailError = InputValidator.validateEmail(email);
    if (emailError != null) {
      debugPrint('[RESET] Invalid email format: $emailError');
      return (success: false, message: emailError);
    }

    final sanitizedEmail = email.trim();

    try {
      await auth.sendPasswordResetEmail(email: sanitizedEmail);
      debugPrint('[RESET] Password reset email sent successfully');
      debugPrint('[RESET] END');

      // Security: Generic success message regardless of whether email exists
      return (
        success: true,
        message:
            'If an account exists for this email, a reset link has been sent.',
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('[RESET] FirebaseAuthException: ${e.code}');

      // Security: For user-not-found, still return generic success
      // to prevent account enumeration attacks
      if (e.code == 'user-not-found') {
        debugPrint('[RESET] User not found (hidden from UI for security)');
        debugPrint('[RESET] END');
        return (
          success: true,
          message:
              'If an account exists for this email, a reset link has been sent.',
        );
      }

      // Handle other specific errors
      final errorMessage = switch (e.code) {
        'invalid-email' => 'Please enter a valid email address.',
        'too-many-requests' =>
          'Too many requests. Please try again in a few minutes.',
        'network-request-failed' =>
          'Network error. Please check your connection and try again.',
        _ => 'Failed to send reset email. Please try again.',
      };

      debugPrint('[RESET] END - error: $errorMessage');
      return (success: false, message: errorMessage);
    } catch (e) {
      debugPrint('[RESET] Unexpected error: $e');
      debugPrint('[RESET] END');
      return (
        success: false,
        message: 'An unexpected error occurred. Please try again.',
      );
    }
  }
}

/// Internal cache structure for user data (memory only, not persisted)
class _CachedUserData {
  final bool exists;
  final String? name;
  final DateTime cachedAt;

  _CachedUserData({
    required this.exists,
    this.name,
    required this.cachedAt,
  });

  bool get isValid => 
    DateTime.now().difference(cachedAt) < const Duration(minutes: 5);
}
