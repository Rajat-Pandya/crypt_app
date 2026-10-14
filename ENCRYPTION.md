# Encryption Documentation

## Overview

Crypt implements **military-grade end-to-end encryption** using a hybrid cryptographic system combining RSA-4096 asymmetric encryption with AES-256-GCM symmetric encryption.

## Encryption Architecture

### Hybrid Encryption

```
┌─────────────────────────────────────────────────────────────┐
│                    HYBRID ENCRYPTION                         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │   Message   │───▶│ AES-256-GCM │───▶│   Ciphertext    │ │
│  │  (Plain)    │    │ (Data Key)  │    │ + Encrypted Key │ │
│  └─────────────┘    └─────────────┘    └─────────────────┘ │
│                                                  │          │
│                                                  ▼          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │ RSA Private │───▶│  Decrypt    │───▶│   AES-256 Key   │ │
│  │    Key      │    │   AES Key   │    │                 │ │
│  └─────────────┘    └─────────────┘    └─────────────────┘ │
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │ RSA Public  │───▶│  Encrypt    │───▶│  Encrypted Key  │ │
│  │    Key      │    │   AES Key   │    │                 │ │
│  └─────────────┘    └─────────────┘    └─────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Key Types

### 1. RSA-4096 Key Pair

- **Purpose**: Asymmetric encryption for AES key exchange
- **Generation**: Generated on device during setup
- **Storage**: 
  - Private key: Android Keystore / iOS Keychain
  - Public key: Firestore (shared with contacts)
- **Rotation**: Automatic on new device or security event

### 2. AES-256-GCM Keys

- **Purpose**: Symmetric encryption of message content
- **Generation**: Unique key per message
- **Size**: 256 bits (32 bytes)
- **Mode**: GCM (Galois/Counter Mode) with authentication

### 3. HMAC-SHA256 Keys

- **Purpose**: Message integrity verification
- **Generation**: Derived from master key
- **Usage**: Prevents tampering with ciphertext

## Encryption Process

### Sending a Message

```dart
Future<EncryptedMessage> encryptMessage(String plaintext) async {
  // 1. Generate random AES-256 key
  final aesKey = _generateAESKey(256);
  
  // 2. Generate random IV (12 bytes for GCM)
  final iv = _generateIV(12);
  
  // 3. Encrypt message with AES-GCM
  final ciphertext = await AESGCM.encrypt(
    plaintext: plaintext,
    key: aesKey,
    iv: iv,
  );
  
  // 4. Encrypt AES key with RSA public key
  final encryptedKey = await RSA.encrypt(
    data: base64Encode(aesKey),
    publicKey: recipientPublicKey,
  );
  
  // 5. Compute HMAC for integrity
  final hmac = await HMAC.compute(
    data: ciphertext,
    key: hmacKey,
  );
  
  // 6. Generate nonce for replay protection
  final nonce = _generateSecureRandom(16);
  
  return EncryptedMessage(
    ciphertext: ciphertext,
    encryptedKey: encryptedKey,
    iv: base64Encode(iv),
    hmac: hmac,
    nonce: nonce,
    timestamp: DateTime.now(),
  );
}
```

### Receiving a Message

```dart
Future<String> decryptMessage(EncryptedMessage encrypted) async {
  // 1. Verify HMAC for integrity
  final isValid = await HMAC.verify(
    data: encrypted.ciphertext,
    signature: encrypted.hmac,
    key: hmacKey,
  );
  
  if (!isValid) {
    throw IntegrityException('Message tampered');
  }
  
  // 2. Check nonce for replay protection
  if (_isReplay(encrypted.nonce)) {
    throw ReplayException('Message replay detected');
  }
  
  // 3. Decrypt AES key with RSA private key
  final aesKeyBase64 = await RSA.decrypt(
    ciphertext: encrypted.encryptedKey,
    privateKey: myPrivateKey,
  );
  final aesKey = base64Decode(aesKeyBase64);
  
  // 4. Decrypt message with AES-GCM
  final plaintext = await AESGCM.decrypt(
    ciphertext: encrypted.ciphertext,
    key: aesKey,
    iv: base64Decode(encrypted.iv),
  );
  
  // 5. Store nonce to prevent replay
  _storeNonce(encrypted.nonce);
  
  return plaintext;
}
```

## Security Features

### 1. Forward Secrecy

Keys are rotated automatically:
- On new device login
- After key compromise detection
- Periodic rotation (configurable)

Old keys are archived for decrypting historical messages.

### 2. Replay Attack Protection

Each message includes:
- **Nonce**: 16-byte cryptographically secure random
- **Timestamp**: Server timestamp verification
- **Sequence Number**: Monotonic counter per session

### 3. Integrity Verification

HMAC-SHA256 ensures:
- Message not tampered in transit
- Ciphertext integrity
- Metadata authenticity

### 4. Device Trust

Multi-device security:
- New devices require approval via OTP
- Device fingerprinting
- Trust score calculation
- Automatic device blocking on suspicious activity

## Key Management

### Key Generation

```dart
class KeyGeneration {
  static Future<KeyPair> generateRSA4096() async {
    // Use secure random number generator
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(await _getSeed()));
    
    // Generate RSA key pair
    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
        secureRandom,
      ));
    
    return keyGen.generateKeyPair();
  }
}
```

### Key Storage

```dart
class KeyStorage {
  static Future<void> storePrivateKey(String keyJson) async {
    // Android: Store in Keystore
    // iOS: Store in Keychain
    await secureStorage.write(
      key: 'device_private_key',
      value: keyJson,
    );
  }
  
  static Future<String?> loadPrivateKey() async {
    return await secureStorage.read(key: 'device_private_key');
  }
}
```

### Key Rotation

```dart
class KeyRotation {
  static Future<void> rotateKeys() async {
    // 1. Archive old keys
    await _archiveCurrentKeys();
    
    // 2. Generate new RSA key pair
    final newKeys = await KeyGeneration.generateRSA4096();
    
    // 3. Store new private key
    await KeyStorage.storePrivateKey(newKeys.privateKey);
    
    // 4. Upload new public key
    await _uploadPublicKey(newKeys.publicKey);
    
    // 5. Notify contacts of key change
    await _notifyKeyRotation();
  }
}
```

## Security Guarantees

### What is Protected

✅ **Message Content**: End-to-end encrypted
✅ **Message Metadata**: Protected (sender, receiver, timestamp visible)
✅ **Message Integrity**: HMAC verification
✅ **Replay Attacks**: Nonce protection
✅ **Man-in-the-Middle**: RSA key exchange

### What is Not Protected

⚠️ **Message Existence**: Server knows messages exist
⚠️ **Chat Participants**: Server knows who talks to whom
⚠️ **Message Timestamps**: Visible to server
⚠️ **Message Size**: Visible to server
⚠️ **Device IP Addresses**: Visible to Firebase

## Vulnerabilities and Mitigations

| Threat | Mitigation |
|--------|-----------|
| Man-in-the-Middle | RSA public key pinning, certificate validation |
| Replay Attacks | Cryptographic nonces, timestamps |
| Key Compromise | Forward secrecy, key rotation |
| Brute Force | AES-256 (computationally infeasible) |
| Side-Channel | Constant-time operations where possible |
| Metadata Leakage | Minimize metadata, use TLS |

## Compliance

### Standards

- **NIST**: AES-256 and RSA-4096 recommended
- **NSA Suite B**: Compatible with top-secret requirements
- **GDPR**: Data protection by design

### Best Practices

1. **Never store keys in plain text**
2. **Rotate keys regularly**
3. **Validate all inputs**
4. **Use constant-time operations**
5. **Secure random number generation**
6. **Zero memory after use**

---

*For implementation details, see `lib/services/secure_chat_service.dart`*
