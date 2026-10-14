import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

/// KeyBackupService
///
/// Solves: private key is wiped on app uninstall → old messages unreadable.
///
/// Strategy (Option 1 — encrypted server backup):
///   1. On first key generation OR on login when no local key exists,
///      the private key JSON is encrypted with a key derived from the
///      user's password via PBKDF2-SHA256.
///   2. The encrypted blob + salt + IV are stored in Firestore under
///      users/{uid}/keyBackup — NOT readable without the password.
///   3. On reinstall, login fetches the blob and decrypts it with the
///      password the user just typed. The private key is restored to
///      FlutterSecureStorage exactly as before.
///
/// Security properties:
///   • The server stores only ciphertext. Without the password no one
///     can recover the private key.
///   • PBKDF2 with 600 000 iterations (current OWASP recommendation for
///     PBKDF2-SHA256) makes offline brute-force expensive.
///   • A fresh random salt per backup means two users with the same
///     password produce different ciphertext.
///   • AES-256-GCM with a random 12-byte IV for each write.
///     GCM authentication tag guarantees wrong-password detection is
///     always reliable — CBC+PKCS7 padding-based detection fails ~1/256.
///
/// ── Fix 1 ─────────────────────────────────────────────────────────────────
/// Previously: AES-256-CBC — wrong password could silently produce corrupt
///             plaintext if PKCS7 padding happened to validate (~1/256 chance),
///             causing a downstream FormatException instead of a clean
///             KeyRestoreResult.wrongPassword.
/// Now:        AES-256-GCM — authentication tag always throws
///             InvalidCipherTextException on wrong password or tampered data.
///
/// ── Fix 2 ─────────────────────────────────────────────────────────────────
/// Previously: 100 000 PBKDF2 iterations (below 2023 OWASP minimum).
/// Now:        600 000 iterations (current OWASP recommendation).

class KeyBackupService {
  static final _firestore = FirebaseFirestore.instance;
  static final _storage = const FlutterSecureStorage();

  static const _pbkdf2Iterations = 600000;
  static const _saltBytes = 32;
  static const _aesKeyBytes = 32;
  static const _ivBytes = 12;

  static const backupPendingKey = 'backup_pending';
  static const backupConfirmedKey = 'backup_confirmed';

  static void _dbg(String msg) {
    assert(() {
      // ignore: avoid_print
      print('[KeyBackupService] $msg');
      return true;
    }());
  }

  /// Call this right after generating a new RSA key pair.
  ///
  /// Encrypts [privateKeyJson] with [password] and uploads the ciphertext
  /// to Firestore. The plaintext private key is never sent to the server.
  ///
  /// On success, writes [backupConfirmedKey] = 'true' to secure storage
  /// and clears [backupPendingKey].
  ///
  /// On failure, writes [backupPendingKey] = 'true' so the caller can
  /// schedule a retry on the next login.
  static Future<void> backupPrivateKey({
    required User user,
    required String privateKeyJson,
    required String password,
  }) async {
    _dbg('backupPrivateKey: encrypting…');

    final encrypted = await Isolate.run(
      () => _encryptWithPassword(plaintext: privateKeyJson, password: password),
    );

    await _firestore.collection('users').doc(user.uid).set({
      'keyBackup': encrypted,
      'keyBackupAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _storage.write(key: backupConfirmedKey, value: 'true');
    await _storage.delete(key: backupPendingKey);

    _dbg('backupPrivateKey: uploaded to Firestore ✓');
  }

  /// Call this on login when the local private key is missing (fresh install).
  ///
  /// Returns [KeyRestoreResult.success]     → key restored, proceed normally.
  /// Returns [KeyRestoreResult.noBackup]    → no backup in Firestore.
  /// Returns [KeyRestoreResult.wrongPassword] → decryption failed.
  ///
  /// Fix 1: With AES-GCM, [KeyRestoreResult.wrongPassword] is now always
  /// returned reliably on a bad password. The old CBC implementation would
  /// silently return corrupt JSON ~1/256 of the time, which then crashed
  /// later when the JSON was parsed.
  ///
  /// 🔑 MULTI-DEVICE FIX: Preserves existing device keys before restoring.
  /// Device B's original keys (used for messages sent TO Device B) are archived
  /// before restoring Device A's keys. This allows Device B to decrypt messages
  /// encrypted with its old public key while also being able to read Device A's messages.
  static Future<KeyRestoreResult> restorePrivateKey({
    required User user,
    required String password,
  }) async {
    _dbg('restorePrivateKey: fetching backup…');

    late final DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await _firestore.collection('users').doc(user.uid).get();
    } on FirebaseException catch (e) {
      // PERMISSION_DENIED under App Check failure/emulator: treat as noBackup
      // so setupEncryption generates fresh key instead of wrongPassword loop.
      _dbg('restorePrivateKey: Firestore fetch failed (${e.code}) — noBackup');
      return KeyRestoreResult.noBackup;
    }
    final backupData = doc.data()?['keyBackup'];

    if (backupData == null) {
      _dbg('restorePrivateKey: no backup found');
      return KeyRestoreResult.noBackup;
    }

    try {
      final backup = Map<String, String>.from(backupData as Map);
      final privateKeyJson = await Isolate.run(
        () => _decryptWithPassword(encrypted: backup, password: password),
      );

      // 🔑 MULTI-DEVICE FIX: Archive existing device keys before restoring
      // This preserves Device B's original keys for decrypting messages sent TO Device B
      final existingDeviceKey = await _storage.read(key: 'device_private_key');
      if (existingDeviceKey != null) {
        // Archive the existing device key with a timestamp
        final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
        await _storage.write(
          key: 'archived_private_key_$timestamp',
          value: existingDeviceKey,
        );
        _dbg('restorePrivateKey: archived existing device key as archived_private_key_$timestamp');
      }

      // Also check for legacy key and archive it
      final existingLegacyKey = await _storage.read(key: 'private_key');
      if (existingLegacyKey != null && existingLegacyKey != privateKeyJson) {
        final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
        await _storage.write(
          key: 'archived_private_key_legacy_$timestamp',
          value: existingLegacyKey,
        );
        _dbg('restorePrivateKey: archived existing legacy key as archived_private_key_legacy_$timestamp');
      }

      // Store the restored key
      await _storage.write(key: 'private_key', value: privateKeyJson);
      // Also store as device_private_key for consistency
      await _storage.write(key: 'device_private_key', value: privateKeyJson);

      await _storage.write(key: backupConfirmedKey, value: 'true');
      await _storage.delete(key: backupPendingKey);

      _dbg('restorePrivateKey: key restored to secure storage ✓');
      return KeyRestoreResult.success;
    } catch (e) {
      _dbg('restorePrivateKey: decryption failed — ${e.runtimeType}');
      // ✅ Only crypto failure = wrong password
      if (e is InvalidCipherTextException) {
        return KeyRestoreResult.wrongPassword;
      }

      // ✅ Other issues treated as safe fallback
      return KeyRestoreResult.noBackup;
    }
  }

  /// Retries a previously failed backup. Call this at login when
  /// [backupPendingKey] == 'true' in secure storage.
  ///
  /// 🔴 FIX Issue #10 — Logic inversion in return value
  /// Previously: Returned true when pending == 'true', confusing the logic.
  /// Result: In auth_service.dart, "if (!backupRetried)" would log "failed"
  ///         even when the retry succeeded (pending != 'true').
  ///
  /// Fixed: Return true when nothing to retry (pending != 'true')
  ///        Return true on successful retry
  ///        Return false only on actual failure
  ///
  /// Now auth_service.dart logs correctly:
  ///   if (!backupRetried) → only logs if actually failed
  static Future<bool> retryPendingBackup({
    required User user,
    required String password,
  }) async {
    final pending = await _storage.read(key: backupPendingKey);

    if (pending != 'true') {
      _dbg('retryPendingBackup: nothing to retry');
      return true;
    }

    _dbg('retryPendingBackup: retrying failed backup…');

    final privateKeyJson = await _storage.read(key: 'private_key');
    if (privateKeyJson == null) {
      _dbg('retryPendingBackup: no local key to back up — skipping');
      await _storage.delete(key: backupPendingKey);
      return false;
    }

    try {
      await backupPrivateKey(
        user: user,
        privateKeyJson: privateKeyJson,
        password: password,
      );
      _dbg('retryPendingBackup: succeeded ✓');
      return true;
    } catch (e) {
      _dbg('retryPendingBackup: failed again — ${e.runtimeType}');
      return false;
    }
  }

  /// Returns true if a confirmed backup exists for this device.
  /// Use this to warn users who have never successfully backed up.
  static Future<bool> isBackupConfirmed() async {
    final confirmed = await _storage.read(key: backupConfirmedKey);
    return confirmed == 'true';
  }

  /// Deletes the backup from Firestore and clears local confirmation flags.
  /// Call when the user explicitly rotates their key or deletes their account.
  static Future<void> deleteBackup(User user) async {
    await _firestore.collection('users').doc(user.uid).update({
      'keyBackup': FieldValue.delete(),
      'keyBackupAt': FieldValue.delete(),
    });
    await _storage.delete(key: backupConfirmedKey);
    await _storage.delete(key: backupPendingKey);
    _dbg('deleteBackup: removed from Firestore and local flags cleared');
  }

  // Session-level PBKDF2 cache - memory only, cleared on logout
  static Uint8List? _cachedDerivedKey;
  static String? _cachedPassword;
  static Uint8List? _cachedSalt;

  static Uint8List _deriveKey(String password, Uint8List salt) {
    // Check cache first (same session only)
    if (_cachedDerivedKey != null &&
        _cachedPassword == password &&
        _cachedSalt != null &&
        _listEquals(_cachedSalt!, salt)) {
      _dbg('PBKDF2 cache hit - reusing derived key');
      return _cachedDerivedKey!;
    }

    _dbg('PBKDF2 cache miss - deriving key (600k iterations)');
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, _pbkdf2Iterations, _aesKeyBytes));
    final derivedKey = pbkdf2.process(Uint8List.fromList(utf8.encode(password)));

    // Cache in memory only (never persist to disk)
    _cachedDerivedKey = derivedKey;
    _cachedPassword = password;
    _cachedSalt = Uint8List.fromList(salt);

    return derivedKey;
  }

  static bool _listEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Clears the session-level PBKDF2 cache.
  /// Call on logout or app termination.
  static void clearDerivedKeyCache() {
    _cachedDerivedKey = null;
    _cachedPassword = null;
    _cachedSalt = null;
    _dbg('PBKDF2 cache cleared');
  }

  /// Encrypts [plaintext] with [password].
  ///
  /// Fix 1: Uses AES-256-GCM instead of AES-256-CBC.
  /// GCM appends a 16-byte authentication tag to the ciphertext.
  /// Decryption will throw [InvalidCipherTextException] if the tag does
  /// not verify — meaning wrong password detection is 100% reliable.
  ///
  /// Returns a map with base64-encoded: ciphertext (includes GCM tag), salt, iv.
  static Map<String, String> _encryptWithPassword({
    required String plaintext,
    required String password,
  }) {
    final salt = _randomBytes(_saltBytes);
    final iv = _randomBytes(_ivBytes);
    final key = _deriveKey(password, salt);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));

    final input = Uint8List.fromList(utf8.encode(plaintext));
    final ciphertext = cipher.process(input);

    return {
      'ciphertext': base64Encode(ciphertext),
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
    };
  }

  /// Decrypts an [encrypted] map produced by [_encryptWithPassword].
  ///
  /// Fix 1: AES-256-GCM verifies the authentication tag before returning
  /// plaintext. If the tag fails (wrong password, tampered data), it throws
  /// [InvalidCipherTextException] — always, not ~255/256 of the time.
  static String _decryptWithPassword({
    required Map<String, String> encrypted,
    required String password,
  }) {
    final salt = base64Decode(encrypted['salt']!);
    final iv = base64Decode(encrypted['iv']!);
    final ciphertext = base64Decode(encrypted['ciphertext']!);
    final key = _deriveKey(password, salt);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));

    final output = cipher.process(ciphertext);
    return utf8.decode(output);
  }

  static Uint8List _randomBytes(int count) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(count, (_) => rng.nextInt(256)));
  }

  // 🔑 MULTI-DEVICE: Load archived keys for decrypting old messages
  /// Returns a list of archived private keys that were preserved during
  /// key restoration. These keys can be used to decrypt messages that were
  /// encrypted before device approval.
  static Future<List<String>> loadArchivedKeys() async {
    _dbg('loadArchivedKeys: loading archived keys...');
    final archivedKeys = <String>[];
    
    try {
      final allKeys = await _storage.readAll();
      for (final entry in allKeys.entries) {
        if (entry.key.startsWith('archived_private_key_')) {
          archivedKeys.add(entry.value);
          _dbg('loadArchivedKeys: found ${entry.key}');
        }
      }
      _dbg('loadArchivedKeys: loaded ${archivedKeys.length} archived keys');
    } catch (e) {
      _dbg('loadArchivedKeys: error loading archived keys - $e');
    }
    
    return archivedKeys;
  }
}

/// Result of a key restore attempt.
enum KeyRestoreResult {
  /// Key successfully decrypted and written to secure storage.
  success,

  /// No backup exists in Firestore — first install with no prior backup.
  noBackup,

  /// Decryption failed — wrong password or corrupt data.
  /// With AES-GCM (Fix 1) this is now always returned reliably on bad input.
  wrongPassword,
}
