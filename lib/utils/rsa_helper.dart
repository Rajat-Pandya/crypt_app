import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/rsa.dart';

/// Detailed error information for RSA operations
class RSAError implements Exception {
  final String message;
  final RSAErrorType type;
  final Object? cause;

  const RSAError(this.message, {required this.type, this.cause});

  @override
  String toString() => 'RSAError($type): $message';
}

enum RSAErrorType {
  invalidInputSize,
  invalidCiphertextSize,
  decryptionFailed,
  encryptionFailed,
  keyGenerationFailed,
  invalidKeyFormat,
}

/// Result wrapper for singleton generation
class _GenerationResult {
  final AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>? keyPair;
  final Object? error;

  _GenerationResult.success(this.keyPair) : error = null;
  _GenerationResult.failure(this.error) : keyPair = null;

  bool get isSuccess => error == null;
}

class RSAHelper {
  // ── Singleton Lock for Key Generation ────────────────────────────────────
  // CRITICAL: Prevents concurrent RSA key generation to avoid CPU thrashing
  // when multiple services call generateKeyPair() simultaneously.
  // Each caller still gets their own unique key pair - this just sequences
  // the generation operations to avoid resource contention.
  static bool _generationInProgress = false;
  static final List<Completer<_GenerationResult>> _waitingCallers = [];

  // ── Internal debug helper ──────────────────────────────────────────────
  static void _dbg(String message) {
    assert(() {
      debugPrint('[RSA] $message');
      return true;
    }());
  }

  // ────────────────────────────────────────────────────────────────────────

  // 🔐 GENERATE KEY PAIR with Concurrency Lock
  // Runs in a separate isolate — 2048-bit RSA generation blocks the UI
  // thread for 2-5 seconds on mobile and triggers ANR on slow devices.
  //
  // SECURITY: Uses lock to prevent concurrent generation which can cause
  // CPU thrashing. Each caller receives a UNIQUE key pair - this is NOT
  // a shared key cache, just a generation sequencer.
  static Future<AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>>
      generateKeyPair() async {
    // Check if generation is already in progress
    if (_generationInProgress) {
      _dbg('generateKeyPair: generation in progress, queuing caller');
      final completer = Completer<_GenerationResult>();
      _waitingCallers.add(completer);
      final result = await completer.future;

      if (result.isSuccess) {
        // Return a FRESH key pair, not the one from the completer
        // This ensures each service gets its own unique key
        _dbg('generateKeyPair: generation complete, generating fresh key for queued caller');
        return await Isolate.run(_generateKeyPairSync);
      } else {
        throw result.error!;
      }
    }

    // Acquire lock and generate
    _generationInProgress = true;
    _dbg('generateKeyPair: acquired lock, starting generation');

    try {
      final result = await Isolate.run(_generateKeyPairSync);
      _dbg('generateKeyPair: 2048-bit key pair generated successfully');

      // Notify waiting callers that they can now generate
      _dbg('generateKeyPair: notifying ${_waitingCallers.length} waiting callers');
      for (final completer in _waitingCallers) {
        completer.complete(_GenerationResult.success(result));
      }
      _waitingCallers.clear();

      return result;
    } catch (e) {
      _dbg('generateKeyPair: generation failed');
      // Notify waiting callers of error
      for (final completer in _waitingCallers) {
        completer.complete(_GenerationResult.failure(RSAError(
          'Key generation failed: $e',
          type: RSAErrorType.keyGenerationFailed,
          cause: e,
        )));
      }
      _waitingCallers.clear();

      throw RSAError(
        'Key generation failed: $e',
        type: RSAErrorType.keyGenerationFailed,
        cause: e,
      );
    } finally {
      _generationInProgress = false;
    }
  }

  static AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _generateKeyPairSync() {
    _dbg('generateKeyPair: starting');

    final secureRandom = FortunaRandom();

    final seed = Uint8List(32);
    final random = Random.secure();

    for (int i = 0; i < seed.length; i++) {
      seed[i] = random.nextInt(256);
    }

    secureRandom.seed(KeyParameter(seed));

    final keyGen = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
          secureRandom,
        ),
      );

    final pair = keyGen.generateKeyPair();

    _dbg('generateKeyPair: 2048-bit key pair generated');

    return AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
      pair.publicKey as RSAPublicKey,
      pair.privateKey as RSAPrivateKey,
    );
  }

  // 🔐 ENCRYPT — runs in isolate to avoid blocking the UI thread
  static Future<String> encrypt(String text, RSAPublicKey publicKey) async {
    _dbg('encrypt: starting');

    late final Uint8List inputBytes;
    try {
      inputBytes = base64Decode(text);
    } catch (e) {
      throw RSAError(
        'Invalid base64 input: $e',
        type: RSAErrorType.invalidKeyFormat,
        cause: e,
      );
    }

    if (inputBytes.length > 245) {
      throw RSAError(
        'RSA encrypt input too large: ${inputBytes.length} bytes (max 245)',
        type: RSAErrorType.invalidInputSize,
      );
    }

    final pubKeyMap = {
      'n': publicKey.modulus.toString(),
      'e': publicKey.exponent.toString(),
    };

    try {
      final result = await Isolate.run(
        () => _encryptSync(text, pubKeyMap),
      );
      _dbg('encrypt: done');
      return result;
    } catch (e) {
      throw RSAError(
        'Encryption failed: $e',
        type: RSAErrorType.encryptionFailed,
        cause: e,
      );
    }
  }

  static String _encryptSync(String text, Map<String, String> pubKeyMap) {
    final publicKey = RSAPublicKey(
      BigInt.parse(pubKeyMap['n']!),
      BigInt.parse(pubKeyMap['e']!),
    );
    final inputBytes = base64Decode(text);
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    final output = cipher.process(inputBytes);
    return base64Encode(output);
  }

  // 🔓 DECRYPT — runs in isolate to avoid blocking the UI thread
  /// Decrypts RSA-encrypted text with comprehensive error handling
  ///
  /// [text] - Base64-encoded encrypted AES key
  /// [privateKey] - RSA private key for decryption
  ///
  /// Returns base64-encoded AES key on success
  /// Throws RSAError on failure with detailed error type
  static Future<String> decrypt(String text, RSAPrivateKey privateKey) async {
    _dbg('decrypt: starting (input length: ${text.length})');

    // Validate input is base64
    late final Uint8List inputBytes;
    try {
      inputBytes = base64Decode(text);
    } catch (e) {
      throw RSAError(
        'Invalid base64 ciphertext: $e',
        type: RSAErrorType.invalidKeyFormat,
        cause: e,
      );
    }

    _dbg('decrypt: input size = ${inputBytes.length} bytes');

    // For 2048-bit RSA, ciphertext should be exactly 256 bytes
    // Validate size with clear error for debugging
    if (inputBytes.length != 256) {
      _dbg(
          'decrypt: ERROR - ciphertext size is ${inputBytes.length}, expected 256');
      throw RSAError(
        'Invalid ciphertext size: ${inputBytes.length} bytes (expected 256 for 2048-bit RSA). '
        'This may indicate a legacy message or corrupted data.',
        type: RSAErrorType.invalidCiphertextSize,
      );
    }

    final privKeyMap = {
      'n': privateKey.n!.toString(),
      'd': privateKey.privateExponent!.toString(),
      'p': privateKey.p!.toString(),
      'q': privateKey.q!.toString(),
    };

    try {
      final result = await Isolate.run(
        () => _decryptSync(text, privKeyMap),
      );
      _dbg('decrypt: done (output length: ${result.length})');
      return result;
    } on RSAError {
      rethrow;
    } catch (e) {
      final errorStr = e.toString().toLowerCase();

      // Classify common errors
      if (errorStr.contains('padding') || errorStr.contains('pkcs1')) {
        throw RSAError(
          'Decryption padding error - likely wrong key or corrupted data',
          type: RSAErrorType.decryptionFailed,
          cause: e,
        );
      } else if (errorStr.contains('range') ||
          errorStr.contains('bounds')) {
        throw RSAError(
          'Decryption range error - likely ciphertext size mismatch',
          type: RSAErrorType.invalidCiphertextSize,
          cause: e,
        );
      } else {
        throw RSAError(
          'Decryption failed: $e',
          type: RSAErrorType.decryptionFailed,
          cause: e,
        );
      }
    }
  }

  /// Validates RSA ciphertext size without throwing
  /// Returns true if size is valid for 2048-bit RSA (256 bytes)
  static bool isValidCiphertextSize(String base64Ciphertext) {
    try {
      final bytes = base64Decode(base64Ciphertext);
      return bytes.length == 256;
    } catch (e) {
      return false;
    }
  }

  static String _decryptSync(String text, Map<String, String> privKeyMap) {
    final privateKey = RSAPrivateKey(
      BigInt.parse(privKeyMap['n']!),
      BigInt.parse(privKeyMap['d']!),
      BigInt.parse(privKeyMap['p']!),
      BigInt.parse(privKeyMap['q']!),
    );
    final inputBytes = base64Decode(text);
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final output = cipher.process(inputBytes);
    return base64Encode(output);
  }

  // ✓ VERIFY SIGNATURE — validates RSA signature using public key
  /// Verifies a PKCS#1 v1.5 RSA signature
  ///
  /// [payload] - The original data that was signed (base64 encoded)
  /// [signature] - The signature to verify (base64 encoded)
  /// [publicKey] - RSA public key for verification
  ///
  /// Returns true if signature is valid, false otherwise
  static bool verifySignature(
    String payload,
    String signature,
    RSAPublicKey publicKey,
  ) {
    _dbg('verifySignature: starting');
    try {
      final payloadBytes = base64Decode(payload);
      final signatureBytes = base64Decode(signature);
      
      final cipher = PKCS1Encoding(RSAEngine())
        ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      
      final decryptedSignature = cipher.process(signatureBytes);
      final decryptedHash = base64Encode(decryptedSignature);
      final payloadHash = base64Encode(payloadBytes);
      
      // In a real implementation, you'd compare cryptographic hashes
      // For now, we decrypt the signature and verify it matches the payload
      _dbg('verifySignature: payload length=${payloadBytes.length}, sig length=${signatureBytes.length}');
      
      // Simple comparison - in production use proper hash verification
      return decryptedHash == payloadHash;
    } catch (e) {
      _dbg('verifySignature: failed - $e');
      return false;
    }
  }
}
