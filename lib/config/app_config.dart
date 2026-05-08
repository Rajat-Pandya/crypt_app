/// ── AppConfig ──────────────────────────────────────────────────────────────
///
/// Secrets are NEVER written in this file or comments.
/// All values are injected at compile time via --dart-define flags.
///
/// ── DO NOT commit real secrets to version control ────────────────────────
/// Even if they appear only in comments, committed secrets are compromised.
/// Use environment variables or secure secret management instead.
///
/// ── How to run in emulator ─────────────────────────────────────────────────
/// Android Studio:
///   Run → Edit Configurations → Additional run args:
///   --dart-define=ONESIGNAL_APP_ID=<your-actual-id>
///   --dart-define=CF_WORKER_URL=<your-actual-url>
///
/// Command line:
///   flutter run \
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id> \
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
/// ── How to build a test APK ───────────────────────────────────────────────
///   flutter build apk \
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id> \
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
/// ── Getting your values ────────────────────────────────────────────────────
/// OneSignal App ID:
///   1. Log into OneSignal dashboard
///   2. Navigate to your app
///   3. Settings → Keys & IDs → App ID
///
/// Cloudflare Worker URL:
///   1. Log into Cloudflare dashboard
///   2. Workers & Pages → your worker
///   3. Copy the deployed URL from the right panel
///
/// Store these values in a secure .env file or secret manager.
/// DO NOT paste them in code comments.
/// ────────────────────────────────────────────────────────────────────────
library;

class AppConfig {
  AppConfig._();

  /// OneSignal Application ID.
  /// Injected via: --dart-define=ONESIGNAL_APP_ID=<value>
  /// If empty, push notifications are disabled (non-fatal).
  static const String oneSignalAppId = String.fromEnvironment(
    'ONESIGNAL_APP_ID',
    defaultValue: '',
  );

  /// Cloudflare Worker URL for push notification delivery.
  /// Injected via: --dart-define=CF_WORKER_URL=<value>
  /// If empty, push notifications are disabled (non-fatal).
  static const String cfWorkerUrl = String.fromEnvironment(
    'CF_WORKER_URL',
    defaultValue: '',
  );

  /// Returns true only if both required values were provided at build time.
  /// If false in debug, a warning will be printed to the console.
  static bool get isValid =>
      oneSignalAppId.isNotEmpty && cfWorkerUrl.isNotEmpty;
}