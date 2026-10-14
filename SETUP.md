# Setup Guide

## Prerequisites

Before setting up Crypt, ensure you have:

- Flutter SDK 3.24+ installed
- Android Studio or Xcode configured
- Firebase CLI installed
- OneSignal account
- Git configured

## Quick Start

### 1. Clone Repository

```bash
git clone https://github.com/yourusername/crypt.git
cd crypt
```

### 2. Install Dependencies

```bash
flutter pub get
```

### 3. Firebase Setup

#### Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Click "Create Project"
3. Enter project name (e.g., "crypt-messenger")
4. Enable Google Analytics (optional)
5. Accept terms and create project

#### Enable Authentication

1. In Firebase Console, go to "Authentication"
2. Click "Get Started"
3. Enable "Email/Password" sign-in method
4. Save

#### Setup Firestore

1. Go to "Firestore Database"
2. Click "Create Database"
3. Choose "Start in production mode"
4. Select location (e.g., "asia-south1" for India)
5. Create database

#### Add Android App

1. In Firebase Console, click "Add App" → "Android"
2. Enter package name: `com.example.crypt_app`
3. Download `google-services.json`
4. Place file in `android/app/`

#### Deploy Security Rules

```bash
firebase deploy --only firestore:rules
```

### 4. OneSignal Setup

1. Create account at [OneSignal](https://onesignal.com)
2. Create new app
3. Select "Mobile Push Notifications"
4. Choose "Flutter" as SDK
5. Copy App ID
6. Paste in `lib/config/app_config.dart`:

```dart
static const String oneSignalAppId = 'YOUR_ONESIGNAL_APP_ID';
```

### 5. Build Configuration

#### Android

In `android/app/build.gradle`, ensure:

```gradle
android {
    compileSdkVersion 34
    
    defaultConfig {
        applicationId "com.example.crypt_app"
        minSdkVersion 21
        targetSdkVersion 34
    }
}
```

#### iOS

In `ios/Runner/Info.plist`, add:

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to take profile photos</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs photo library access to send images</string>
```

### 6. Run the App

#### Development Mode

```bash
flutter run
```

#### With Production Config

```bash
flutter run --dart-define=PROD=true
```

## Configuration

### Environment Variables

Create `.env` file in project root:

```env
# Firebase
FIREBASE_API_KEY=your_api_key
FIREBASE_APP_ID=your_app_id
FIREBASE_MESSAGING_SENDER_ID=your_sender_id
FIREBASE_PROJECT_ID=your_project_id

# OneSignal
ONESIGNAL_APP_ID=your_onesignal_app_id

# Optional: Custom Cloud Functions URL
CF_WORKER_URL=https://your-worker.workers.dev
```

### App Configuration

Edit `lib/config/app_config.dart`:

```dart
class AppConfig {
  // Firebase
  static const String firebaseProjectId = 'your-project-id';
  
  // OneSignal
  static const String oneSignalAppId = 'your-onesignal-app-id';
  
  // Features
  static const bool enableDebugLogs = true; // Set false for production
  static const bool enableEncryption = true;
  static const bool enableGames = true;
}
```

## Troubleshooting

### Build Errors

**Error**: `google-services.json not found`

**Solution**: Download file from Firebase Console and place in `android/app/`

---

**Error**: `Firebase Auth not working`

**Solution**: Enable Email/Password sign-in in Firebase Console → Authentication

---

**Error**: `Firestore permission denied`

**Solution**: Deploy security rules:
```bash
firebase deploy --only firestore:rules
```

---

**Error**: `OneSignal notifications not working`

**Solution**: 
1. Verify OneSignal App ID is correct
2. Check OneSignal dashboard for device registration
3. Ensure Firebase Cloud Messaging is enabled

### Runtime Errors

**Error**: `Encryption key missing`

**Solution**: Log out and log in again to regenerate keys

---

**Error**: `Messages not decrypting`

**Solution**: 
1. Check if sender's key has changed
2. Wait for key synchronization
3. Restart app

---

**Error**: `Offline mode not working`

**Solution**: 
1. Ensure Hive is initialized properly
2. Check storage permissions
3. Verify first-time setup completed

## Development

### Running Tests

```bash
flutter test
```

### Building APK

```bash
flutter build apk --release
```

### Building App Bundle

```bash
flutter build appbundle --release
```

### Building iOS

```bash
flutter build ios --release
```

## Production Checklist

Before deploying to production:

- [ ] Update `AppConfig.enableDebugLogs` to `false`
- [ ] Set `AppConfig.isProduction` to `true`
- [ ] Verify Firebase security rules
- [ ] Enable Firebase App Check
- [ ] Configure OneSignal for production
- [ ] Test on multiple devices
- [ ] Verify encryption works
- [ ] Check offline functionality
- [ ] Validate push notifications
- [ ] Review error handling
- [ ] Update privacy policy
- [ ] Add terms of service

## Support

For issues and questions:

1. Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
2. Review [ARCHITECTURE.md](ARCHITECTURE.md)
3. Open GitHub issue
4. Contact maintainers

---

*For detailed architecture information, see [ARCHITECTURE.md](ARCHITECTURE.md)*
