# Security Model

This document describes the security architecture of the Crypt application.

## Encryption Overview

Crypt is an end-to-end encrypted chat application. Messages are encrypted on the sender's device and can only be decrypted by the intended recipient.

### Encryption Stack

| Layer | Algorithm | Key Size |
|-------|-----------|--------|
| Message Encryption | AES-256-CBC | 256-bit |
| Key Exchange | RSA-2048 | 2048-bit |
| Key Derivation | PBKDF2-SHA256 | 600,000 iterations |
| Backup Encryption | AES-256-GCM | 256-bit |

## Threat Model

### Protected Against

- **Server-side reading**: Server stores only ciphertext, never plaintext
- **Network eavesdropping**: All communication uses TLS 1.2+
- **Offline storage attacks**: Private keys stored in platform secure storage (Android Keystore / iOS Keychain)
- **Replay attacks**: Each message uses unique AES key and IV
- **Credential theft**: Private keys never transmitted in plaintext

### Not Protected Against (Known Limitations)

- **Device compromise**: If device is rooted/jailbroken, keys may be extractable
- **Side-channel attacks**: Timing attacks on decryption (mitigated via constant-time operations)
- **Social engineering**: Users may be tricked into revealing passwords
- **Forward secrecy**: Compromised keys unlock all historical messages
- **Key reuse**: Same RSA key decrypts all messages (not rotated automatically)

## Key Management

### Key Generation

1. RSA-2048 key pair generated on first login
2. Private key stored in FlutterSecureStorage (backed by platform keychain)
3. Public key uploaded to Firestore (accessible to all users)

### Key Backup

1. Private key encrypted with user's password using PBKDF2 (600k iterations)
2. Encrypted backup stored in Firestore under `users/{uid}/keyBackup`
3. On reinstall, user enters password to restore private key

### Key Rotation

- Manual rotation via Settings → Security → "Rotate Encryption Key"
- Auto-rotation recommended after 1 year of use

## Data Storage

### Firestore Collections

| Collection | Data Type | Access Control |
|------------|-----------|----------------|
| `users/{uid}` | Profile, publicKey | Authenticated read, owner write |
| `chat_rooms/{roomId}` | Room metadata | Room participants only |
| `chat_rooms/{roomId}/messages` | Encrypted messages | Room participants only |

### Local Storage

- Private key: FlutterSecureStorage (Android Keystore / iOS Keychain)
- App preferences: SharedPreferences (encrypted)
- Session state: In-memory only

## Authentication

- Firebase Authentication (email/password)
- Email verification required before first message
- Session timeout: 30 minutes of inactivity
- OneSignal for push notifications (via Firebase UID)

## Security Best Practices

1. **Never log sensitive data**: Use debug flags, never print keys//passwords
2. **Validate input**: All user input sanitized before processing
3. **Use secure random**: `Random.secure()` for all crypto operations
4. **Handle errors gracefully**: Never leak sensitive details in error messages
5. **Keep dependencies updated**: Use Dependabot for security patches

## Reporting Security Issues

If you discover a security vulnerability, please:

1. **Do NOT** open a public GitHub issue
2. Email security concerns privately
3. Include reproduction steps
4. Allow time for remediation before disclosure

## Security Checklist

- [x] No secrets in source code
- [x] All secrets via environment variables
- [x] Firestore security rules enforce access control
- [x] Firebase App Check enabled (production)
- [x] No plaintext message storage
- [x] Private keys in platform secure storage
- [x] PBKDF2 with 600k+ iterations
- [x] AES-256-GCM for authenticated encryption
- [x] Session timeout implemented
- [x] Email verification required