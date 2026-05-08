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

class RSAHelper {
  // ── Internal debug helper ──────────────────────────────────────────────
  static void _dbg(String message) {
    assert(() {
      debugPrint('[RSA] $message');
      return true;
    }());
  }

  // ────────────────────────────────────────────────────────────────────────

  // 🔐 GENERATE KEY PAIR
  // Runs in a separate isolate — 2048-bit RSA generation blocks the UI
  // thread for 2-5 seconds on mobile and triggers ANR on slow devices.
  static Future<AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>>
  generateKeyPair() async {
    return await Isolate.run(_generateKeyPairSync);
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
    final inputBytes = base64Decode(text);

    if (inputBytes.length > 245) {
      throw Exception(
        'RSA encrypt input too large: ${inputBytes.length} bytes',
      );
    }

    final pubKeyMap = {
      'n': publicKey.modulus.toString(),
      'e': publicKey.exponent.toString(),
    };

    final result = await Isolate.run(
      () => _encryptSync(text, pubKeyMap),
    );
    _dbg('encrypt: done');
    return result;
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
  static Future<String> decrypt(String text, RSAPrivateKey privateKey) async {
    _dbg('decrypt: starting');
    final inputBytes = base64Decode(text);

    if (inputBytes.length != 256) {
      throw Exception(
        'RSA ciphertext wrong size: ${inputBytes.length} bytes',
      );
    }

    final privKeyMap = {
      'n': privateKey.n!.toString(),
      'd': privateKey.privateExponent!.toString(),
      'p': privateKey.p!.toString(),
      'q': privateKey.q!.toString(),
    };

    final result = await Isolate.run(
      () => _decryptSync(text, privKeyMap),
    );
    _dbg('decrypt: done');
    return result;
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
}
