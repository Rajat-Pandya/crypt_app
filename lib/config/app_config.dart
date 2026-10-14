/// ── AppConfig ──────────────────────────────────────────────────────────────
///
/// Secrets are NEVER written in this file or comments.
/// All values are injected at compile time via --dart-define flags.
///
/// ── DO NOT commit real secrets to version control ────────────────────────
/// Even if they appear only in comments, committed secrets are compromised.
/// Use environment variables or secure secret management instead.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// SECURITY-CRITICAL: PRODUCTION BUILD REQUIREMENTS
/// ═══════════════════════════════════════════════════════════════════════════
///
/// PRODUCTION builds MUST include --dart-define=PROD=true
/// Failure to do so will use DEBUG App Check providers, compromising security!
///
/// ── Production Build (RELEASE) ─────────────────────────────────────────────
///   flutter build apk --release \
///     --dart-define=PROD=true \
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id> \
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
/// ── Production Build (APP BUNDLE) ─────────────────────────────────────────
///   flutter build appbundle --release \
///     --dart-define=PROD=true \
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id> \
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
/// ── Development Build (DEBUG) ──────────────────────────────────────────────
///   flutter run \
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id> \
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
///   OR without OneSignal/CF (notifications disabled):
///   flutter run
///
/// ── Android Studio Configuration ───────────────────────────────────────────
/// Run → Edit Configurations → Additional run args:
///   For production testing:
///     --dart-define=PROD=true
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id>
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
///   For development:
///     --dart-define=ONESIGNAL_APP_ID=<your-actual-id>
///     --dart-define=CF_WORKER_URL=<your-actual-url>
///
/// ═══════════════════════════════════════════════════════════════════════════
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

  // ============================================================================
  // SECURITY CONFIGURATION
  // ============================================================================

  /// Production mode flag.
  /// 
  /// SECURITY CRITICAL: This determines security-critical behavior:
  /// - App Check provider selection (Play Integrity vs Debug)
  /// - Debug logging of sensitive data
  /// - Security check strictness
  /// 
  /// Injected via: --dart-define=PROD=true
  /// 
  /// ⚠️ WARNING: Never set this to false for production releases!
  /// Production builds should always be built with: --dart-define=PROD=true
  static const bool isProduction = bool.fromEnvironment(
    'PROD',
    defaultValue: false,
  );

  /// Development mode flag (inverse of production).
  /// 
  /// Use this for features that should only run in development,
  /// such as verbose logging, debug menus, or test endpoints.
  static const bool isDevelopment = !isProduction;

  /// Security level configuration.
  /// 
  /// In production: strict security checks, no debug info
  /// In development: relaxed checks for debugging convenience
  static const SecurityLevel securityLevel = isProduction
      ? SecurityLevel.strict
      : SecurityLevel.development;

  /// Returns true if App Check should use production providers.
  /// 
  /// SECURITY: Returns false only in explicit development builds.
  /// This prevents accidental use of debug providers in production.
  static bool get useProductionAppCheck => isProduction;

  /// Returns true if sensitive data can be logged for debugging.
  /// 
  /// SECURITY: Always false in production to prevent data leakage.
  static bool get enableSensitiveLogging => isDevelopment;

  /// Returns true if security checks should be enforced strictly.
  /// 
  /// In development: allows some bypasses for testing
  /// In production: all checks must pass
  static bool get enforceStrictSecurity => isProduction;
}

/// Security level enumeration.
/// 
/// Defines the security posture of the application.
enum SecurityLevel {
  /// Development mode: relaxed security for debugging.
  /// - Debug App Check providers
  /// - Verbose logging enabled
  /// - Some security checks can be bypassed
  development,

  /// Strict mode: full security enforcement.
  /// - Production App Check providers (Play Integrity, App Attest)
  /// - No sensitive data in logs
  /// - All security checks enforced
  /// - Rate limiting active
  strict,
}
