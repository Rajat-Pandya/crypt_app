# Crypt - End-to-End Encrypted Chat Application

<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="Crypt App Icon">
</p>

<p align="center">
  <a href="https://flutter.dev/">
    <img src="https://img.shields.io/badge/Flutter-3.11+-02569B?style=flat-square&logo=flutter" alt="Flutter">
  </a>
  <a href="https://firebase.google.com/">
    <img src="https://img.shields.io/badge/Firebase-Ready-FFCA28?style=flat-square&logo=firebase" alt="Firebase">
  </a>
  <a href="https://opensource.org/licenses/MIT">
    <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="License">
  </a>
</p>

---

## Overview

Crypt is a production-ready Flutter chat application featuring **end-to-end encryption** (E2EE) for secure messaging. Messages are encrypted on the sender's device and can only be decrypted by the intended recipient - even the server cannot read the message content.

### Key Security Features

- **AES-256-CBC** for message encryption
- **RSA-2048** for secure key exchange
- **PBKDF2** (600k iterations) for key derivation
- **Client-side encryption** - server never sees plaintext
- **Secure key backup** - encrypted with user's password

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Crypt Architecture                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐    │
│  │   Sender    │────▶│   Firebase  │────▶│  Receiver   │    │
│  │   Device    │     │   Firestore  │     │   Device    │    │
│  └──────────────┘     └──────────────┘     └──────────────┘    │
│         │                    │                    │              │
│         ▼                    │                    ▼              │
│  ┌──────────────┐          │            ┌──────────────┐       │
│  │   Encrypt   │          │            │   Decrypt   │       │
│  │  (AES-256) │          │            │  (AES-256)  │       │
│  └──────────────┘          │            └──────────────┘       │
│         │                  │                    │              │
│         ▼                  │                    ▼              │
│  ┌──────────────┐          │            ┌──────────────┐       │
│  │   RSA Wrap  │          │            │   RSA Unwrap │       │
│  │  (Receiver) │          │            │   (Sender)   │       │
│  └──────────────┘          │            └──────────────┘       │
│                             │                                  │
└─────────────────────────────┴──────────────────────────────────┘
```

### Technology Stack

| Layer | Technology |
|-------|------------|
| **Frontend** | Flutter 3.11+ |
| **Backend** | Firebase (Auth, Firestore) |
| **Notifications** | OneSignal + Cloudflare Worker |
| **Encryption** | PointyCastle (RSA/AES) |
| **Secure Storage** | Flutter Secure Storage |
| **State** | StreamBuilder + ValueNotifier |

---

## Features

### Core Messaging
- ✅ End-to-end encrypted messages
- ✅ Real-time message delivery
- ✅ Read receipts (sent/delivered/seen)
- ✅ Typing indicators
- ✅ Message reactions
- ✅ Reply to messages
- ✅ Starred messages
- ✅ Message search
- ✅ Delete for me / Delete for everyone

### Chat Management
- ✅ Pinned chats
- ✅ Mute notifications
- ✅ Chat clear
- ✅ Block/unblock users

### Security
- ✅ RSA key pair generation
- ✅ Secure key backup to cloud
- ✅ Key mismatch detection
- ✅ Session timeout (30 min)
- ✅ Email verification

### Social
- ✅ User profiles
- ✅ Online status
- ✅ Last seen

### Games
- ✅ Connect Four
- ✅ Number Guess

---

## Encryption Details

### How It Works

1. **Key Generation**: Each user has an RSA-2048 key pair
2. **Key Exchange**: Public keys stored in Firestore (anyone can see)
3. **Message Encryption**:
   - Generate random AES-256 key per message
   - Encrypt message with AES
   - Encrypt AES key with recipient's RSA public key
4. **Decryption**:
   - Decrypt AES key with RSA private key
   - Decrypt message with AES key

### Key Backup

Private keys are encrypted with the user's password using:
- **PBKDF2**: 600,000 iterations
- **AES-256-GCM**: Authenticated encryption
- **Random salt**: Per-device unique

The backup is stored in Firestore but never transmitted in plaintext.

---

## Project Structure

```
lib/
├── main.dart                 # App entry point
├── config/
│   └── app_config.dart     # Runtime configuration
├── screens/
│   ├── chat_screen.dart    # Chat view
│   ├── chat_list_screen.dart
│   ├── login_screen.dart
│   ├── settings_screen.dart
│   ├── profile_screen.dart
│   └── ...
├── services/
│   ├── auth_service.dart       # Authentication
│   ├── chat_service.dart       # Messaging
│   ├── key_backup_service.dart
│   └── session_manager.dart
├── utils/
│   ├── encryption.dart     # AES helpers
│   ├── rsa_helper.dart    # RSA helpers
│   └── input_validator.dart
└── widgets/
    └── error_boundary.dart
```

---

## Setup Instructions

### Prerequisites

- Flutter 3.11+
- Firebase project
- OneSignal account (optional)
- Cloudflare Worker (optional)

### 1. Clone & Install

```bash
git clone https://github.com/yourusername/crypt.git
cd crypt
flutter pub get
```

### 2. Firebase Setup

1. Create a Firebase project
2. Enable Authentication (Email/Password)
3. Enable Firestore
4. Download `google-services.json` → `android/app/`

### 3. Configure (Optional)

```bash
# OneSignal App ID
flutter run --dart-define=ONESIGNAL_APP_ID=your-app-id

# Cloudflare Worker URL  
flutter run --dart-define=CF_WORKER_URL=https://your-worker.workers.dev
```

### 4. Build

```bash
# Debug APK
flutter build apk --debug

# Release APK
flutter build apk --release
```

---

## Screenshots

<div align="center">
  <img src=".github/screenshots/chat.png" width="240" alt="Chat Screen">
  <img src=".github/screenshots/chat-list.png" width="240" alt="Chat List">
  <img src=".github/screenshots/settings.png" width="240" alt="Settings">
</div>

---

## Security Considerations

- Private keys stored in platform keychain (Android Keystore / iOS Keychain)
- Keys never transmitted in plaintext
- PBKDF2 with 600k iterations for key backup
- AES-256-GCM for authenticated encryption
- Session timeout after 30 minutes of inactivity

---

## Future Roadmap

- [ ] Group messaging support
- [ ] Voice messages
- [ ] Image/file sharing
- [ ] Message editing history
- [ ] Cross-platform key verification
- [ ] Push notification improvements

---

## Contributing

Contributions are welcome! Please read the contributing guidelines before submitting PRs.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Disclaimer

This application uses encryption to protect message privacy. While the implementation follows industry best practices, no guarantee can be made regarding absolute security. Users should exercise caution when sharing sensitive information.
