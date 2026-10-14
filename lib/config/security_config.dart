/// Enterprise-grade cryptographic security configuration
/// 
/// These values are tuned for production security while maintaining
/// acceptable performance. All timeouts and limits are based on
/// industry best practices.
class SecurityConfig {
  // ==========================================================================
  // REPLAY PROTECTION
  // ==========================================================================
  
  /// Size of cryptographically secure nonce in bytes
  /// 128 bits provides sufficient entropy against collision
  static const int nonceSizeBytes = 16;
  
  /// Maximum acceptable timestamp skew in minutes
  /// Messages with timestamps outside this window are rejected
  static const int maxTimestampSkewMinutes = 5;
  
  /// How long to retain processed nonces for replay detection (hours)
  /// 72 hours provides sufficient coverage while managing memory
  static const int nonceRetentionHours = 72;
  
  /// How often to clean up the nonce cache (minutes)
  static const int nonceCleanupIntervalMinutes = 60;

  // ==========================================================================
  // SESSION VALIDATION
  // ==========================================================================
  
  /// Maximum session validity in hours before revalidation required
  static const int sessionValidityHours = 24;
  
  /// Session considered stale after this many hours of inactivity
  static const int sessionStaleThresholdHours = 12;
  
  /// Grace period for key rotation detection (minutes)
  /// New keys are considered "recent" during this period
  static const int keyRotationGracePeriodMinutes = 5;
  
  /// Maximum key age before rotation recommended (days)
  static const int keyRotationRecommendedDays = 90;
  
  /// Maximum key age before rotation required (days)
  static const int keyRotationRequiredDays = 180;

  // ==========================================================================
  // TRUST SCORING
  // ==========================================================================
  
  /// Minimum trust score for secure operations (0-100)
  static const int minTrustScore = 50;
  
  /// Trust score below which session is considered compromised
  static const int criticalTrustScore = 30;
  
  /// Trust score below which warnings should be shown
  static const int warningTrustScore = 70;
  
  /// Penalty for decryption failure (points)
  static const int decryptionFailurePenalty = 10;
  
  /// Penalty for key mismatch (points)
  static const int keyMismatchPenalty = 20;
  
  /// Penalty for stale session (points per hour)
  static const int staleSessionPenaltyPerHour = 5;
  
  /// Recovery per successful decryption (points)
  static const int successfulDecryptionRecovery = 5;

  // ==========================================================================
  // MISMATCH DETECTION
  // ==========================================================================
  
  /// Number of consecutive failures before cache is cleared
  static const int mismatchCacheClearThreshold = 5;
  
  /// Number of consecutive failures before user notification
  static const int mismatchWarningThreshold = 3;
  
  /// Number of failures before recommending reauthentication
  static const int mismatchReauthThreshold = 10;
  
  /// Time window for counting consecutive failures (minutes)
  static const int mismatchTimeWindowMinutes = 30;

  // ==========================================================================
  // HMAC CONFIGURATION
  // ==========================================================================
  
  /// HMAC algorithm: SHA-256
  static const int hmacAlgorithm = 256;
  
  /// HMAC key size in bytes
  static const int hmacKeySizeBytes = 32;
  
  /// HMAC output size in bytes (SHA-256)
  static const int hmacOutputSizeBytes = 32;

  // ==========================================================================
  // KEY FINGERPRINTING
  // ==========================================================================
  
  /// Fingerprint size in bytes (128 bits of security)
  static const int fingerprintSizeBytes = 16;
  
  /// Fingerprint display format: XXXX-XXXX-XXXX-XXXX
  static const String fingerprintFormat = 'XXXX-XXXX-XXXX-XXXX';

  // ==========================================================================
  // CACHE CONFIGURATION
  // ==========================================================================
  
  /// Public key cache TTL for server-sourced keys (hours)
  static const int publicKeyCacheTTLHours = 1;
  
  /// Public key cache TTL for cache-sourced keys (minutes)
  static const int publicKeyCacheTTLMinutes = 5;
  
  /// Private key cache TTL (hours) - long lived as it's encrypted
  static const int privateKeyCacheTTLHours = 24;
  
  /// Maximum reconnect times to retain
  static const int maxReconnectHistory = 100;

  // ==========================================================================
  // RATE LIMITING
  // ==========================================================================
  
  /// Maximum decryption retries per message
  static const int maxDecryptRetries = 3;
  
  /// Maximum concurrent decryption operations
  static const int maxConcurrentDecrypts = 10;
  
  /// Maximum retries for loading receiver key
  static const int maxReceiverKeyRetries = 5;
  
  /// Delay between retries (seconds)
  static const int retryDelaySeconds = 3;

  // ==========================================================================
  // RECONNECT DETECTION
  // ==========================================================================
  
  /// Minimum offline time to trigger reconnect validation (seconds)
  static const int reconnectValidationThresholdSeconds = 60;
  
  /// Maximum suspicious reconnects in 5 minutes
  static const int maxSuspiciousReconnects = 3;
  
  /// Reconnect debounce time (milliseconds)
  static const int reconnectDebounceMs = 2000;
}

// ============================================================================
// SECURITY CONSTANTS
// ============================================================================

class SecurityConstants {
  // Cache markers
  static const String decryptPending = '\x00PENDING\x00';
  static const String decryptFailed = '\x00FAILED\x00';
  static const String decryptKeyError = '\x00KEY_ERR\x00';
  static const String decryptSecurityError = '\x00SEC_ERR\x00';
  
  // Storage keys
  static const String sessionIdKey = 'encryption_session_id';
  static const String sessionCreatedKey = 'encryption_session_created';
  static const String lastKeyVersionKey = 'last_known_key_version';
  static const String trustRecordPrefix = 'trust_record_';
  
  // Key prefixes
  static const String privateKeyStorageKey = 'private_key';
  static const String publicKeyStorageKey = 'public_key';
  static const String offlineQueuePrefix = 'offline_msg_';
}
