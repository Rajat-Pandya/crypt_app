import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:crypt_app/services/session_manager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/rsa_helper.dart';
import '../utils/input_validator.dart';
import 'key_backup_service.dart';
import 'game_service.dart';

enum KeyStatus { synced, mismatch, regenerated }

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

  static bool loginInProgress = false;
  static const _publicKeyPendingKey = 'public_key_upload_pending';
  static const publicKeyPendingKey =
      _publicKeyPendingKey; // public alias for main.dart

  static void _dbg(String message) {
    debugPrint('[AuthService] $message');
  }

  static Future<({KeyStatus status, KeyMismatchDetail? mismatchDetail})>
  setupEncryption(User user, {String? password}) async {
    final existingKeyStrCheck = await storage.read(key: "private_key");
    if (existingKeyStrCheck == null && password != null) {
      _dbg('no local key found — attempting restore from backup');
      final result = await KeyBackupService.restorePrivateKey(
        user: user,
        password: password,
      );
      switch (result) {
        case KeyRestoreResult.success:
          _dbg('key restored from backup — proceeding with synced state');
          break;
        case KeyRestoreResult.noBackup:
          _dbg('noBackup: no backup found — will generate a fresh key');
          // Do NOT block login here. The user has no local key and no backup,
          // meaning either this is a new device or the backup was never uploaded.
          // Generating a fresh key is the only viable path forward.
          // Old messages encrypted to the previous key will be unreadable,
          // but blocking login entirely is worse — the user can't do anything.
          break;
        case KeyRestoreResult.wrongPassword:
          _dbg('restore: wrong password — aborting to prevent data loss');
          return (status: KeyStatus.mismatch, mismatchDetail: null);
      }
    }

    final existingKeyStr = await storage.read(key: "private_key");

    if (existingKeyStr != null) {
      final keyData = jsonDecode(existingKeyStr) as Map<String, dynamic>;
      final hasPublicExponent = keyData["e"] != null;

      if (!hasPublicExponent) {
        _dbg('old key format detected — regenerating');
        await storage.delete(key: "private_key");
      } else {
        late final DocumentSnapshot<Map<String, dynamic>> doc;
        try {
          doc = await _firestore.collection("users").doc(user.uid).get();
        } on FirebaseException catch (e) {
          _dbg(
            'setupEncryption: Firestore key check failed (${e.code}) — assuming synced',
          );
          await storage.write(key: 'encryption_setup_done', value: 'true');
          return (status: KeyStatus.synced, mismatchDetail: null);
        }
        final firestoreKey = doc.data()?["publicKey"];

        final hasValidPublicKey =
            firestoreKey != null &&
            firestoreKey["n"] != null &&
            firestoreKey["e"] != null;

        if (!hasValidPublicKey) {
          _dbg('public key missing from Firestore — re-uploading');

          await _firestore.collection("users").doc(user.uid).set({
            "publicKey": {"n": keyData["n"], "e": keyData["e"]},
            "publicKeyVersion": _keyVersion(keyData["n"] as String),
          }, SetOptions(merge: true));

          _dbg('public key re-uploaded');
          // ✅ FIX #2: Set flag after successful key re-upload
          await storage.write(key: 'encryption_setup_done', value: 'true');
          return (status: KeyStatus.synced, mismatchDetail: null);
        }

        final localModulus = keyData["n"].toString();
        final firestoreModulus = (firestoreKey["n"] as String);

        if (localModulus != firestoreModulus) {
          _dbg('key mismatch detected — awaiting user resolution');

          return (
            status: KeyStatus.mismatch,
            mismatchDetail: KeyMismatchDetail(
              remotePublicKey: {
                "n": firestoreKey["n"] as String,
                "e": firestoreKey["e"] as String,
              },
              localPublicKey: {
                "n": keyData["n"] as String,
                "e": keyData["e"] as String,
              },
            ),
          );
        }

        _dbg('encryption keys verified and in sync');
        // ✅ FIX #1: Set flag after verifying encryption keys are in sync
        await storage.write(key: 'encryption_setup_done', value: 'true');
        return (status: KeyStatus.synced, mismatchDetail: null);
      }
    }

    _dbg('generating new RSA key pair');

    final pair = await RSAHelper.generateKeyPair();
    final publicKey = pair.publicKey;
    final privateKey = pair.privateKey;

    final nStr = publicKey.modulus.toString();
    final eStr = publicKey.exponent.toString();

    final privateKeyData = jsonEncode({
      "n": nStr,
      "e": eStr,
      "d": privateKey.privateExponent.toString(),
      "p": privateKey.p.toString(),
      "q": privateKey.q.toString(),
    });

    // Store private key first - this should always succeed
    await storage.write(key: "private_key", value: privateKeyData);

    // Try to upload public key to Firestore - may fail on emulator due to App Check
    // Don't crash if this fails - user can still use the app
    try {
      await _firestore.collection("users").doc(user.uid).set({
        "publicKey": {"n": nStr, "e": eStr},
        "publicKeyVersion": _keyVersion(nStr),
      }, SetOptions(merge: true));
      _dbg('public key uploaded to Firestore ✓');
    } on FirebaseException catch (e) {
      _dbg('public key upload failed (${e.code}) — marked as pending');
      await storage.write(key: _publicKeyPendingKey, value: 'true');
    }

    // Try to backup encrypted key - may fail due to App Check or network
    if (password != null) {
      try {
        await KeyBackupService.backupPrivateKey(
          user: user,
          privateKeyJson: privateKeyData,
          password: password,
        );
        _dbg('private key backed up to Firestore ✓');
      } catch (e) {
        _dbg('key backup upload failed — ${e.runtimeType} — marked as pending');
        await storage.write(
          key: KeyBackupService.backupPendingKey,
          value: 'true',
        );
      }
    } else {
      _dbg('no password provided — skipping key backup');
      await storage.write(
        key: KeyBackupService.backupPendingKey,
        value: 'true',
      );
    }

    _dbg('RSA key pair generated and saved');
    // Set flag after successful key generation (even if Firestore failed)
    await storage.write(key: 'encryption_setup_done', value: 'true');
    return (status: KeyStatus.regenerated, mismatchDetail: null);
  }

  static Future<void> resolveKeyMismatch({
    required User user,
    required KeyMismatchDetail detail,
    required bool keepLocal,
    String? password, // BUG 3 FIX: needed to attempt immediate restore
  }) async {
    if (keepLocal) {
      _dbg('mismatch resolved: user chose local key → updating Firestore');

      await _firestore.collection("users").doc(user.uid).set({
        "publicKey": detail.localPublicKey,
        "publicKeyVersion": _keyVersion(detail.localPublicKey["n"]!),
      }, SetOptions(merge: true));

      await storage.write(key: 'encryption_setup_done', value: 'true');
      _dbg('encryption_setup_done flag set after local key acceptance');
    } else {
      _dbg('mismatch resolved: user chose remote key → deleting local key');
      await storage.delete(key: "private_key");
      await storage.delete(key: KeyBackupService.backupConfirmedKey);

      // BUG 3 FIX: Attempt immediate restore if password available so the user
      // isn't left with no key and no path forward (which caused infinite loading).
      if (password != null) {
        _dbg('attempting immediate key restore with provided password');
        final result = await KeyBackupService.restorePrivateKey(
          user: user,
          password: password,
        );
        if (result == KeyRestoreResult.success) {
          _dbg('key restored immediately after mismatch resolution');
          await storage.write(key: 'encryption_setup_done', value: 'true');
          return;
        }
        _dbg('immediate restore failed — user will need to re-login');
      }

      // No restore possible — clear flag; user re-logs to retry.
      await storage.delete(key: 'encryption_setup_done');
      _dbg('cleared encryption_setup_done flag after key deletion');
    }
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
    if (auth.currentUser == null) {
      _dbg('saveUserData aborted — no current user');
      return;
    }

    if (auth.currentUser!.uid != user.uid) {
      _dbg('saveUserData aborted — uid mismatch');
      return;
    }

    final playerId = OneSignal.User.pushSubscription.id;

    try {
      String? existingName;
      if (setName) {
        final existingDoc = await _firestore
            .collection("users")
            .doc(user.uid)
            .get();
        existingName = existingDoc.data()?["name"] as String?;
      }

      await _firestore.collection("users").doc(user.uid).set({
        "email": email.trim(),
        if (setName && existingName == null) "name": email.split("@")[0],
        "uid": user.uid,
        "oneSignalPlayerId": playerId,
        "lastSeen": FieldValue.serverTimestamp(),
        "isOnline": isOnline,
      }, SetOptions(merge: true));

      _dbg('user data saved successfully');
    } catch (e) {
      _dbg('saveUserData failed — ${e.runtimeType}');
      rethrow;
    }
  }

  static Future<void> setUserOffline(User user) async {
    try {
      await _firestore.collection("users").doc(user.uid).set({
        "isOnline": false,
        "lastSeen": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      _dbg('setUserOffline failed — ${e.runtimeType}');
    }
  }

  static Future<bool> isEmailVerified() async {
    final user = auth.currentUser;
    if (user == null) return false;

    await user.reload();
    final refreshedUser = auth.currentUser;

    _dbg('emailVerified=${refreshedUser?.emailVerified}');
    return refreshedUser?.emailVerified ?? false;
  }

  static Future<void> sendVerificationEmail() async {
    final user = auth.currentUser;
    if (user == null) throw Exception("No user logged in");

    try {
      _dbg('sending verification email');
      await user.sendEmailVerification();
      _dbg('verification email sent');
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      _dbg('sendVerificationEmail failed — ${e.runtimeType}');
      rethrow;
    }
  }

  static Future<User?> register(String email, String password) async {
    final cleanEmail = email.trim();
    final cleanPassword = password.trim();

    final emailErr = InputValidator.validateEmail(cleanEmail);
    if (emailErr != null) throw FirebaseAuthException(code: "invalid-email");

    if (cleanPassword.length < 6) {
      throw FirebaseAuthException(code: "weak-password");
    }

    _dbg('register: starting user creation');

    final result = await auth.createUserWithEmailAndPassword(
      email: cleanEmail,
      password: cleanPassword,
    );

    final user = result.user!;
    _dbg('register: user created successfully');

    final (:status, :mismatchDetail) = await setupEncryption(
      user,
      password: cleanPassword,
    );
    _dbg('register: encryption setup status=${status.name}');

    await storage.write(key: 'encryption_setup_done', value: 'true');

    try {
      await saveUserData(user, cleanEmail, isOnline: false);
    } catch (e) {
      _dbg('register: saveUserData failed — ${e.runtimeType} — non-fatal');
    }

    try {
      await sendVerificationEmail();
    } catch (e) {
      _dbg('register: verification email failed — ${e.runtimeType}');
    }

    _dbg('register: complete');
    return user;
  }

  static Future<User?> login(
    String email,
    String password, {
    Future<void> Function(KeyMismatchDetail detail)? onMismatch,
  }) async {
    loginInProgress = true;
    try {
      final cleanEmail = email.trim();
      final cleanPassword = password.trim();

      final emailErr = InputValidator.validateEmail(cleanEmail);
      if (emailErr != null) throw FirebaseAuthException(code: "invalid-email");

      if (cleanPassword.isEmpty) {
        throw FirebaseAuthException(code: "wrong-password");
      }

      final result = await auth.signInWithEmailAndPassword(
        email: cleanEmail,
        password: cleanPassword,
      );

      final user = result.user!;
      await user.reload();
      final refreshedUser = auth.currentUser!;

      _dbg('login: emailVerified=${refreshedUser.emailVerified}');

      final (:status, :mismatchDetail) = await setupEncryption(
        refreshedUser,
        password: cleanPassword,
      );

      if (status == KeyStatus.synced) {
        final backupRetried = await KeyBackupService.retryPendingBackup(
          user: refreshedUser,
          password: cleanPassword,
        );
        if (!backupRetried) {
          _dbg(
            'login: pending backup retry failed again — will retry next login',
          );
        }
      }

      // Retry public key upload if it failed during key generation
      final pubKeyPending = await storage.read(key: _publicKeyPendingKey);
      if (pubKeyPending == 'true') {
        try {
          final keyStr = await storage.read(key: 'private_key');
          if (keyStr != null) {
            final kd = jsonDecode(keyStr) as Map<String, dynamic>;
            await _firestore.collection('users').doc(refreshedUser.uid).set({
              'publicKey': {'n': kd['n'], 'e': kd['e']},
              'publicKeyVersion': _keyVersion(kd['n'] as String),
            }, SetOptions(merge: true));
            await storage.delete(key: _publicKeyPendingKey);
            _dbg('login: pending public key upload succeeded ✓');
          }
        } on FirebaseException catch (e) {
          _dbg(
            'login: public key retry failed (${e.code}) — will retry next login',
          );
        }
      }

      if (status == KeyStatus.mismatch && mismatchDetail != null) {
        _dbg('login: key mismatch — delegating to caller');
        if (onMismatch != null) {
          await onMismatch(mismatchDetail);
        }
      }

      _dbg('login: encryption status=${status.name}');

      // Always mark done after onMismatch has resolved (it handles its own key state).
      // For mismatch+detail: onMismatch was called above; for wrongPassword path: mark done to unblock AuthWrapper.
      await storage.write(key: 'encryption_setup_done', value: 'true');

      if (!refreshedUser.emailVerified) {
        _dbg(
          'login: email not yet verified — returning for verification screen',
        );
        return refreshedUser;
      }

      try {
        final doc = await _firestore
            .collection("users")
            .doc(refreshedUser.uid)
            .get();

        if (!doc.exists) {
          await saveUserData(
            refreshedUser,
            cleanEmail,
            isOnline: true,
            setName: false,
          );
        } else {
          await _firestore.collection("users").doc(refreshedUser.uid).set({
            "isOnline": true,
            "lastSeen": FieldValue.serverTimestamp(),
            "emailVerified": true,
          }, SetOptions(merge: true));
        }
      } on FirebaseException catch (e) {
        _dbg('login: Firestore presence update failed (${e.code}) — non-fatal');
      }

      _dbg('login: complete');
      return refreshedUser;
    } finally {
      loginInProgress = false;
    }
  }

  static Future<void> resendVerificationEmail() => sendVerificationEmail();

  static Future<void> logout(BuildContext context) async {
    SessionManager.stopMonitoring();
    GameService.clearAllStreams();

    final user = auth.currentUser;
    if (user != null) {
      await setUserOffline(user);
    }

    // Keep the local private key across logout. Signing out should end the
    // Firebase session, not force a key-restore flow on the next login.
    await storage.delete(key: 'encryption_setup_done');

    await auth.signOut();
    _dbg('user signed out');
  }

  static Future<void> retryPublicKeyUpload(User user) async {
    try {
      final keyStr = await storage.read(key: 'private_key');
      if (keyStr == null) return;
      // Always attempt the upload — it's an idempotent merge write.
      // Firestore queues it offline and syncs on reconnect.
      // No pre-check needed: overwriting with the same key is harmless.
      final kd = jsonDecode(keyStr) as Map<String, dynamic>;
      await _firestore.collection('users').doc(user.uid).set({
        'publicKey': {'n': kd['n'], 'e': kd['e']},
        'publicKeyVersion': _keyVersion(kd['n'] as String),
      }, SetOptions(merge: true));
      await storage.delete(key: _publicKeyPendingKey);
      _dbg('retryPublicKeyUpload: succeeded ✓');
    } on FirebaseException catch (e) {
      _dbg('retryPublicKeyUpload: failed (${e.code}) — will retry later');
    }
  }

  static Future<String?> getPrivateKey() async {
    return await storage.read(key: "private_key");
  }
}
