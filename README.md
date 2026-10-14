# Crypt - Secure Encrypted Messaging App

<p align="center">
  <img src="screenshots/app_icon.png" alt="Crypt App Icon" width="120"/>
</p>

<p align="center">
  <strong>End-to-End Encrypted Messaging with Multiplayer Games</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#encryption">Encryption</a> •
  <a href="#installation">Installation</a> •
  <a href="#screenshots">Screenshots</a>
</p>

---

## Overview

**Crypt** is a production-grade Flutter messaging application featuring military-grade end-to-end encryption, real-time multiplayer games within chats, and comprehensive security features. Built with Firebase backend, the app ensures complete message privacy using AES-256 encryption with RSA-4096 key exchange and HMAC-SHA256 message integrity verification.

### Key Highlights

- **Military-Grade Encryption**: AES-256-GCM with RSA-4096 key exchange
- **Zero-Knowledge Architecture**: Messages encrypted on device, server only sees ciphertext
- **Multiplayer Games**: Play games while chatting (Tic-Tac-Toe, etc.)
- **Cross-Platform**: Works on Android and iOS with Firebase backend
- **Offline Support**: Hive local caching for messages and chat history
- **Push Notifications**: OneSignal integration for message alerts

---

## Features

### Core Messaging
- [x] **End-to-End Encryption**: All messages encrypted with AES-256-GCM
- [x] **Real-time Messaging**: Firestore real-time sync with offline persistence
- [x] **Message Status**: Sent, delivered, and read receipts
- [x] **Typing Indicators**: Real-time typing status
- [x] **Online Presence**: See when contacts are online/offline
- [x] **Message Reactions**: React to messages with emojis
- [x] **Reply to Messages**: Quote and reply to specific messages
- [x] **Starred Messages**: Save important messages
- [x] **Search Messages**: Full-text search in chat history
- [x] **Media Sharing**: Send images and files (coming soon)

### Security Features
- [x] **RSA-4096 Key Pairs**: Asymmetric encryption for key exchange
- [x] **HMAC-SHA256**: Message integrity verification
- [x] **Replay Attack Protection**: Cryptographic nonces for each message
- [x] **Device Trust System**: Multi-device approval with OTP
- [x] **Key Rotation**: Automatic key updates for security
- [x] **Session Recovery**: Secure device-to-device key transfer
- [x] **Biometric Support**: Device-level security integration

### Multiplayer Games
- [x] **In-Chat Games**: Play without leaving the conversation
- [x] **Tic-Tac-Toe**: Classic strategy game
- [x] **Real-time Sync**: Game state synchronized via Firestore
- [x] **Turn-based**: Take turns asynchronously
- [x] **Game Invites**: Challenge friends to games

### User Experience
- [x] **Dark Mode**: Complete dark theme support
- [x] **Responsive UI**: Works on all screen sizes
- [x] **Smooth Animations**: 60fps animations throughout
- [x] **Offline Mode**: Continue chatting without internet
- [x] **Push Notifications**: Never miss a message
- [x] **Profile Customization**: Display names and avatars

---

## Architecture

### Technology Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | Flutter 3.24+ (Dart) |
| **Backend** | Firebase (Firestore, Auth, Storage) |
| **State Management** | BLoC Pattern + Hydrated BLoC |
| **Local Cache** | Hive (NoSQL) |
| **Encryption** | Pointycastle (RSA/AES), Crypto (HMAC) |
| **Push Notifications** | OneSignal |
| **Dependency Injection** | GetIt |

### System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Flutter App                          │
├─────────────────────────────────────────────────────────────┤
│  UI Layer (Screens, Widgets)                                 │
├─────────────────────────────────────────────────────────────┤
│  BLoC Layer (Business Logic)                                 │
│  ├── ChatBloc                                               │
│  ├── AuthBloc                                               │
│  └── GameBloc                                               │
├─────────────────────────────────────────────────────────────┤
│  Service Layer                                              │
│  ├── SecureChatService (Encryption/Decryption)             │
│  ├── ChatUtilService (Core chat operations)                │
│  ├── DeviceService (Device registration)                  │
│  └── GameService (Multiplayer sync)                        │
├─────────────────────────────────────────────────────────────┤
│  Repository Layer                                           │
│  ├── ChatRoomRepository                                     │
│  ├── UserRepository                                         │
│  └── MessageRepository                                      │
├─────────────────────────────────────────────────────────────┤
│  Cache Layer (Hive)                                        │
│  ├── Chat Rooms                                             │
│  ├── Messages                                               │
│  └── User Data                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     Firebase Backend                          │
│  ├── Firestore (Messages, Users, Games)                      │
│  ├── Firebase Auth (Authentication)                        │
│  └── Cloud Functions (Optional)                            │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Send Message:
User Input → Encryption (AES-256) → Firestore → Recipient Device → Decryption → Display

Receive Message:
Firestore → Device → Decryption (AES-256) → Verification (HMAC) → Display

Game State:
User Action → Firestore Transaction → Real-time Sync → All Devices Update
```

---

## Encryption

### Encryption Architecture

Crypt implements a **hybrid encryption system** combining the best of asymmetric and symmetric cryptography:

```
Message Encryption Flow:
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Plaintext  │────▶│  AES-256-GCM │────▶│   Ciphertext      │
│  Message    │     │  (Random Key)│     │   + Encrypted Key │
└─────────────┘     └──────────────┘     └─────────────────┘
                                                  │
                                                  ▼
                                         ┌─────────────────┐
                                         │  RSA-4096        │
                                         │  (Public Key)    │
                                         │  Encrypts AES Key │
                                         └─────────────────┘
```

### Security Features

1. **Key Exchange**: RSA-4096 for secure AES key exchange
2. **Message Encryption**: AES-256-GCM for content
3. **Integrity**: HMAC-SHA256 for tamper detection
4. **Replay Protection**: Unique nonces per message
5. **Forward Secrecy**: Keys rotated periodically

### Key Management

- **Private Key**: Stored in Android Keystore / iOS Keychain
- **Public Key**: Uploaded to Firestore for other users
- **AES Keys**: Unique per message, never reused
- **Key Rotation**: Automatic on device change

---

## Installation

### Prerequisites

- Flutter SDK 3.24+
- Firebase CLI
- Android Studio / Xcode
- OneSignal Account (for push notifications)

### Setup Instructions

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/crypt.git
   cd crypt
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Configure Firebase**
   
   a. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
   
   b. Enable Authentication (Email/Password)
   
   c. Enable Firestore Database
   
   d. Download `google-services.json` and place in `android/app/`
   
   e. Deploy Firestore security rules:
      ```bash
      firebase deploy --only firestore:rules
      ```

4. **Configure OneSignal**
   
   a. Create OneSignal app at [onesignal.com](https://onesignal.com)
   
   b. Copy App ID to `lib/config/app_config.dart`

5. **Build and run**
   ```bash
   flutter run
   ```

### Environment Variables

Create a `.env` file (not committed to git):

```
FIREBASE_API_KEY=your_api_key
ONESIGNAL_APP_ID=your_onesignal_id
```

---

## Screenshots

<p align="center">
  <img src="screenshots/login.png" width="200" />
  <img src="screenshots/chat_list.png" width="200" />
  <img src="screenshots/chat_screen.png" width="200" />
  <img src="screenshots/game.png" width="200" />
</p>

*See [screenshots/](screenshots/) folder for more images*

---

## Project Structure

```
lib/
├── blocs/              # BLoC state management
├── cache/              # Hive local cache
├── config/             # App configuration
├── models/             # Data models
├── repositories/       # Data repositories
├── screens/            # UI screens
├── services/           # Business logic services
├── utils/              # Utilities and helpers
├── widgets/            # Reusable widgets
└── main.dart           # App entry point
```

---

## Firebase Configuration

### Firestore Security Rules

The app uses comprehensive security rules to protect user data:

- **Users**: Only authenticated users can read user profiles
- **Chat Rooms**: Only participants can access room data
- **Messages**: End-to-end encrypted, only sender/receiver can read
- **Games**: Only room participants can play

See `firestore.rules` for complete rules.

### Firestore Indexes

Required composite indexes:

```json
{
  "indexes": [
    {
      "collectionGroup": "chat_rooms",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "users", "arrayConfig": "CONTAINS" },
        { "fieldPath": "lastMessageTime", "order": "DESCENDING" }
      ]
    },
    {
      "collectionGroup": "messages",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "timestamp", "order": "ASCENDING" }
      ]
    }
  ]
}
```

---

## Development

### Running Tests

```bash
flutter test
```

### Building Release APK

```bash
flutter build apk --release
```

### Building iOS

```bash
flutter build ios --release
```

---

## Future Roadmap

- [ ] **Voice Messages**: Encrypted audio messaging
- [ ] **Video Calls**: End-to-end encrypted calls
- [ ] **Group Chats**: Multi-user encrypted conversations
- [ ] **File Sharing**: Secure document sharing
- [ ] **Stories**: Ephemeral photo/video sharing
- [ ] **Web App**: Flutter web support

---

## Security Considerations

⚠️ **Important Security Notes:**

1. **Never commit** `google-services.json` to public repositories
2. **Rotate API keys** regularly
3. **Enable Firebase App Check** for production
4. **Monitor Firestore rules** for security vulnerabilities
5. **Keep dependencies updated** for security patches

---

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- [Flutter](https://flutter.dev) - UI framework
- [Firebase](https://firebase.google.com) - Backend services
- [Pointycastle](https://github.com/bcgit/pc-dart) - Cryptographic library
- [Hive](https://docs.hivedb.dev) - Local database
- [OneSignal](https://onesignal.com) - Push notifications

---

<p align="center">
  <strong>Built with ❤️ and 🔐</strong>
</p>

<p align="center">
  <sub>Crypt - Secure messaging for everyone</sub>
</p>
