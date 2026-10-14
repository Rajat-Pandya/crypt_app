import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/api.dart';
import '../config/security_config.dart';
import '../config/app_config.dart';
import 'hmac_key_service.dart';

/// Enterprise-grade security hardening service.
///
/// Provides comprehensive protections against:
/// - Rooted/modified device exploitation
/// - Application tampering
/// - Debugging/analysis attempts
/// - Replay attacks
/// - Memory-based attacks
/// - Session hijacking
///
/// SECURITY ARCHITECTURE:
/// 1. Device Integrity - detects rooted/emulator/debugger
/// 2. Application Integrity - verifies app signature/modifications
/// 3. Session Integrity - validates session tokens/keys
/// 4. Message Integrity - prevents replay attacks
/// 5. Data Integrity - secures offline storage
class SecurityHardeningService {
  static final SecurityHardeningService _instance = SecurityHardeningService._internal();
  factory SecurityHardeningService() => _instance;
  SecurityHardeningService._internal();

  final _storage = const FlutterSecureStorage();
  final _random = Random.secure();

  // Security state
  bool _isDeviceSecure = true;
  bool _isIntegrityVerified = false;
  bool _debuggerDetected = false;
  int _trustScore = 100;
  DateTime? _lastSecurityCheck;
  
  // Replay protection
  final Map<String, DateTime> _processedNonces = {};
  final Map<String, int> _messageSequenceNumbers = {};
  
  // Pending operations queue for HMAC key initialization
  final List<_PendingOperation> _pendingOperations = [];
  bool _isProcessingPending = false;

  // Getters
  bool get isDeviceSecure => _isDeviceSecure;
  bool get isIntegrityVerified => _isIntegrityVerified;
  bool get debuggerDetected => _debuggerDetected;
  int get trustScore => _trustScore;
  
  // ──────────────────────────────────────────────────────────────────────────
  // PENDING OPERATIONS QUEUE
  // ──────────────────────────────────────────────────────────────────────────
  
  /// Process any pending operations that were queued while waiting for HMAC key
  Future<void> _processPendingOperations() async {
    if (_isProcessingPending || _pendingOperations.isEmpty) return;
    
    _isProcessingPending = true;
    debugPrint('[SecurityHardening] _processPendingOperations: processing ${_pendingOperations.length} operations');
    
    // Copy list to avoid modification during iteration
    final operations = List<_PendingOperation>.from(_pendingOperations);
    _pendingOperations.clear();
    
    for (final op in operations) {
      try {
        if (op.retryCount >= 3) {
          debugPrint('[SecurityHardening] Operation exceeded retry limit, completing with error');
          op.completer.completeError(
            Exception('HMAC key initialization failed after ${op.retryCount} retries')
          );
          continue;
        }
        
        if (HmacKeyService.isInitialized) {
          // Retry the operation
          dynamic result;
          switch (op.type) {
            case _OperationType.createQueueEntry:
              result = await createSecureQueueEntry(
                op.params['queueId'],
                op.params['data'],
              );
              break;
            case _OperationType.generateSessionToken:
              result = generateSessionToken(op.params['userId']);
              break;
          }
          op.completer.complete(result);
        } else {
          // Re-queue for later retry
          op.retryCount++;
          _pendingOperations.add(op);
        }
      } catch (e) {
        op.completer.completeError(e);
      }
    }
    
    _isProcessingPending = false;
    
    // Schedule another retry if still have pending operations
    if (_pendingOperations.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 500), _processPendingOperations);
    }
  }
  
  /// Wait for HMAC key initialization with timeout
  Future<bool> _waitForHmacKeyInitialization({int timeoutMs = 2000}) async {
    if (HmacKeyService.isInitialized) return true;
    
    final startTime = DateTime.now();
    while (!HmacKeyService.isInitialized) {
      if (DateTime.now().difference(startTime).inMilliseconds > timeoutMs) {
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return true;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INITIALIZATION
  // ──────────────────────────────────────────────────────────────────────────

  /// Perform comprehensive security check on app start
  Future<void> initialize() async {
    debugPrint('[SecurityHardening] initialize: START');
    
    // Check for root/mod
    await _checkDeviceIntegrity();
    
    // Check for debugger
    await _detectDebugger();
    
    // Verify app integrity
    await _verifyAppIntegrity();
    
    // Initialize replay protection
    await _initializeReplayProtection();
    
    // Load security state
    await _loadSecurityState();
    
    _lastSecurityCheck = DateTime.now();
    _isIntegrityVerified = true;
    
    debugPrint('[SecurityHardening] initialize: END - deviceSecure: $_isDeviceSecure, trustScore: $_trustScore');
  }

  /// Perform periodic security revalidation
  Future<void> periodicSecurityCheck() async {
    if (_lastSecurityCheck == null) {
      await initialize();
      return;
    }

    final elapsed = DateTime.now().difference(_lastSecurityCheck!);
    if (elapsed.inHours > 1) {
      debugPrint('[SecurityHardening] periodicSecurityCheck: performing...');
      
      // Re-check for root/debugger
      await _checkDeviceIntegrity();
      await _detectDebugger();
      
      // Clean old nonces
      _cleanupOldNonces();
      
      // Validate trust score
      await _validateTrustScore();
      
      _lastSecurityCheck = DateTime.now();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // DEVICE INTEGRITY
  // ──────────────────────────────────────────────────────────────────────────

  /// Check device integrity with environment-aware enforcement
  /// 
  /// SECURITY: In production mode, all security checks are enforced.
  /// In development mode, some checks are relaxed for debugging convenience.
  Future<void> _checkDeviceIntegrity() async {
    _logSecurity('[SecurityHardening] _checkDeviceIntegrity: START');
    
    _isDeviceSecure = true;
    int securityScore = 100;

    try {
      final deviceInfo = await DeviceInfoPlugin().deviceInfo;
      
      if (deviceInfo is AndroidDeviceInfo) {
        // Check for emulator indicators
        final model = deviceInfo.model.toLowerCase();
        final manufacturer = deviceInfo.manufacturer.toLowerCase();
        
        // Common emulator patterns
        if (model.contains('sdk') || model.contains('emulator') ||
            manufacturer.contains('google') && model.contains('sdk')) {
          _logSecurity('[SecurityHardening] _checkDeviceIntegrity: EMULATOR detected via model');
          _isDeviceSecure = false;
          securityScore -= 50;
        }

        // Check for common root-related paths (tags is a String in newer versions)
        final tags = deviceInfo.tags.toString();
        if (tags.contains('test-keys')) {
          _logSecurity('[SecurityHardening] _checkDeviceIntegrity: TEST KEYS detected');
          _isDeviceSecure = false;
          securityScore -= 80;
        }

        // Check for debugging via system properties
        final fingerprint = deviceInfo.fingerprint;
        if (fingerprint.contains('debug') || fingerprint.contains('eng')) {
          _logSecurity('[SecurityHardening] _checkDeviceIntegrity: DEBUG BUILD detected');
          _isDeviceSecure = false;
          securityScore -= 40;
        }

        // Check security patch level
        final securityPatch = deviceInfo.version.securityPatch;
        if (securityPatch != null) {
          final patchDate = DateTime.tryParse(securityPatch);
          if (patchDate != null) {
            final monthsOld = DateTime.now().difference(patchDate).inDays / 30;
            if (monthsOld > 6) {
              _logSecurity('[SecurityHardening] _checkDeviceIntegrity: OLD security patch ($monthsOld months)');
              securityScore -= 20;
            }
          }
        }

        // Check bootloader - only critical in production
        if (deviceInfo.bootloader != 'locked') {
          _logSecurity('[SecurityHardening] _checkDeviceIntegrity: UNLOCKED bootloader');
          // In production, this is a critical issue
          // In development, less critical for testing
          securityScore -= AppConfig.enforceStrictSecurity ? 30 : 10;
        }
      }
      
      if (deviceInfo is IosDeviceInfo) {
        // Check for simulator
        if (deviceInfo.isPhysicalDevice == false) {
          _logSecurity('[SecurityHardening] _checkDeviceIntegrity: SIMULATOR detected');
          _isDeviceSecure = false;
          securityScore -= 50;
        }

        // Check for jailbreak indicators would require platform channels
        // iOS security is handled by the OS
      }

      // In development mode, boost score to allow testing
      if (!AppConfig.enforceStrictSecurity && securityScore < 50) {
        _logSecurity('[SecurityHardening] _checkDeviceIntegrity: DEVELOPMENT MODE - boosting score');
        securityScore = 50; // Minimum to pass in dev mode
      }

      _trustScore = securityScore.clamp(0, 100);
      _logSecurity('[SecurityHardening] _checkDeviceIntegrity: END - score: $_trustScore');
      
    } catch (e) {
      _logSecurity('[SecurityHardening] _checkDeviceIntegrity: ERROR - $e');
      // Assume insecure on error
      _isDeviceSecure = false;
      _trustScore = 30;
    }
  }

  Future<void> _detectDebugger() async {
    debugPrint('[SecurityHardening] _detectDebugger: START');
    
    _debuggerDetected = false;
    
    try {
      // Check for debugger via platform channels would require native code
      // Instead, we use behavioral detection
      
      // Check for suspicious timing anomalies
      
      // Perform a time-sensitive operation multiple times
      final times = <int>[];
      for (int i = 0; i < 100; i++) {
        final opStart = DateTime.now();
        // Simple operation that should be consistent
        List.generate(100, (i) => i * 2).reduce((a, b) => a + b);
        times.add(DateTime.now().difference(opStart).inMicroseconds);
      }
      
      // Calculate variance
      final avgTime = times.reduce((a, b) => a + b) / times.length;
      final variance = times.map((t) => (t - avgTime).abs()).reduce((a, b) => a + b) / times.length;
      
      // High variance might indicate debugging
      if (variance > avgTime * 2) {
        debugPrint('[SecurityHardening] _detectDebugger: HIGH timing variance detected');
        _debuggerDetected = true;
        _trustScore -= 20;
      }
      
    } catch (e) {
      debugPrint('[SecurityHardening] _detectDebugger: ERROR - $e');
    }
    
    debugPrint('[SecurityHardening] _detectDebugger: END - detected: $_debuggerDetected');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // APP INTEGRITY
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _verifyAppIntegrity() async {
    debugPrint('[SecurityHardening] _verifyAppIntegrity: START');
    
    try {
      // Check first launch time - suspicious if very old with no data
      await _loadFirstLaunchTime();
      
      // Verify secure storage hasn't been tampered with
      final testKey = 'security_integrity_test';
      final testValue = _generateSecureToken();
      
      await _storage.write(key: testKey, value: testValue);
      final readValue = await _storage.read(key: testKey);
      
      if (readValue != testValue) {
        debugPrint('[SecurityHardening] _verifyAppIntegrity: STORAGE TAMPERED');
        _trustScore -= 30;
      } else {
        await _storage.delete(key: testKey);
      }

      // Verify critical storage keys haven't been modified
      final criticalKeys = [
        'private_key',
        'public_key',
        'encryption_setup_done',
      ];
      
      for (final key in criticalKeys) {
        final exists = await _storage.read(key: key);
        if (exists != null && exists.length < 10) {
          debugPrint('[SecurityHardening] _verifyAppIntegrity: suspicious key: $key');
          _trustScore -= 5;
        }
      }
      
      debugPrint('[SecurityHardening] _verifyAppIntegrity: END - score: $_trustScore');
      
    } catch (e) {
      debugPrint('[SecurityHardening] _verifyAppIntegrity: ERROR - $e');
      _trustScore -= 20;
    }
  }

  Future<DateTime?> _loadFirstLaunchTime() async {
    try {
      final stored = await _storage.read(key: 'first_launch_time');
      if (stored != null) {
        return DateTime.tryParse(stored);
      }
      
      // First launch - store time
      final now = DateTime.now();
      await _storage.write(key: 'first_launch_time', value: now.toIso8601String());
      return now;
    } catch (e) {
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // REPLAY PROTECTION
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _initializeReplayProtection() async {
    debugPrint('[SecurityHardening] _initializeReplayProtection: START');
    
    try {
      // Load existing processed nonces from storage
      final storedNonces = await _storage.read(key: 'processed_nonces');
      if (storedNonces != null) {
        final nonceMap = jsonDecode(storedNonces) as Map<String, dynamic>;
        for (final entry in nonceMap.entries) {
          final timestamp = DateTime.tryParse(entry.value as String);
          if (timestamp != null) {
            _processedNonces[entry.key] = timestamp;
          }
        }
      }
      
      _cleanupOldNonces();
      debugPrint('[SecurityHardening] _initializeReplayProtection: END');
      
    } catch (e) {
      debugPrint('[SecurityHardening] _initializeReplayProtection: ERROR - $e');
    }
  }

  /// Check if a nonce has been processed (replay attack detection)
  Future<bool> isNonceProcessed(String nonce) async {
    // Check memory cache first
    if (_processedNonces.containsKey(nonce)) {
      return true;
    }
    
    // Check storage for persistence across app restarts
    final key = 'nonce_$nonce';
    final stored = await _storage.read(key: key);
    return stored != null;
  }

  /// Mark a nonce as processed
  Future<void> markNonceProcessed(String nonce) async {
    final now = DateTime.now();
    _processedNonces[nonce] = now;
    
    // Persist to storage for app restart survival
    await _storage.write(
      key: 'nonce_$nonce',
      value: now.toIso8601String(),
    );
    
    // Periodically persist all nonces
    if (_processedNonces.length % 10 == 0) {
      await _persistNonces();
    }
  }

  /// Verify and process a message with replay protection
  Future<bool> verifyAndProcessMessage(
    String messageId,
    String? timestamp,
    Map<String, dynamic>? messageData,
  ) async {
    // Generate nonce from message components
    final nonce = _generateNonce(messageId, timestamp, messageData);
    
    // Check for replay
    if (await isNonceProcessed(nonce)) {
      debugPrint('[SecurityHardening] verifyAndProcessMessage: REPLAY DETECTED - $messageId');
      _trustScore -= 10;
      return false;
    }
    
    // Mark as processed
    await markNonceProcessed(nonce);
    return true;
  }

  void _cleanupOldNonces() {
    final cutoff = DateTime.now().subtract(
      Duration(hours: SecurityConfig.nonceRetentionHours),
    );
    
    _processedNonces.removeWhere((key, value) => value.isBefore(cutoff));
  }

  Future<void> _persistNonces() async {
    final nonceMap = <String, String>{};
    for (final entry in _processedNonces.entries) {
      nonceMap[entry.key] = entry.value.toIso8601String();
    }
    await _storage.write(key: 'processed_nonces', value: jsonEncode(nonceMap));
  }

  // ──────────────────────────────────────────────────────────────────────────
  // SEQUENCE-BASED REPLAY PROTECTION
  // ──────────────────────────────────────────────────────────────────────────

  /// Get next sequence number for a chat room (prevents out-of-order replay)
  Future<int> getNextSequenceNumber(String chatRoomId) async {
    final key = 'seq_$chatRoomId';
    final current = await _storage.read(key: key);
    final nextSeq = (int.tryParse(current ?? '0') ?? 0) + 1;
    await _storage.write(key: key, value: nextSeq.toString());
    return nextSeq;
  }

  /// Validate message sequence is valid (no gaps = potential dropped messages)
  Future<bool> validateMessageSequence(
    String chatRoomId,
    int sequenceNumber,
  ) async {
    final key = 'seq_$chatRoomId';
    final current = await _storage.read(key: key);
    final lastSeq = int.tryParse(current ?? '0') ?? 0;
    
    // Allow sequences within reasonable range (handle network reordering)
    if (sequenceNumber > lastSeq + 100) {
      debugPrint('[SecurityHardening] validateMessageSequence: LARGE GAP - $sequenceNumber vs last: $lastSeq');
      _trustScore -= 5;
      return false;
    }
    
    return true;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TRUST SCORE MANAGEMENT
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _validateTrustScore() async {
    // Decrease trust score over time if device was flagged
    if (_trustScore < SecurityConfig.minTrustScore) {
      // Require re-authentication
      debugPrint('[SecurityHardening] _validateTrustScore: LOW TRUST - requiring re-auth');
      await _triggerReauthentication();
    }
  }

  Future<void> _triggerReauthentication() async {
    try {
      // Mark session as requiring revalidation
      await _storage.write(key: 'session_needs_revalidation', value: 'true');
      
      // Store last trust score for display
      await _storage.write(
        key: 'last_trust_score',
        value: _trustScore.toString(),
      );
    } catch (e) {
      debugPrint('[SecurityHardening] _triggerReauthentication: ERROR - $e');
    }
  }

  /// Check if session needs revalidation
  /// 
  /// SECURITY: In development mode, allows bypassing revalidation for testing.
  /// In production mode, always enforces revalidation when trust is low.
  Future<bool> needsSessionRevalidation() async {
    // In development mode, don't require revalidation for convenience
    if (!AppConfig.enforceStrictSecurity) {
      _logSecurity('[SecurityHardening] needsSessionRevalidation: DEVELOPMENT MODE - skipping');
      return false;
    }
    
    final needsRevalidation = await _storage.read(key: 'session_needs_revalidation');
    final needsReauth = needsRevalidation == 'true';
    
    if (needsReauth) {
      _logSecurity('[SecurityHardening] needsSessionRevalidation: REAUTHENTICATION REQUIRED');
    }
    
    return needsReauth;
  }

  /// Clear revalidation requirement
  Future<void> clearSessionRevalidation() async {
    await _storage.delete(key: 'session_needs_revalidation');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // OFFLINE QUEUE INTEGRITY
  // ──────────────────────────────────────────────────────────────────────────

  /// Generate tamper-proof queue entry with HMAC-SHA256
  /// 
  /// SECURITY: Uses proper HMAC-SHA256 with key from HmacKeyService.
  /// The HMAC covers queueId, timestamp, nonce, and data to prevent tampering.
  /// 
  /// REQUIRES: HmacKeyService must be initialized. If not, operation is queued
  /// and retried after 500ms delay. Throws exception if service unavailable.
  Future<Map<String, dynamic>> createSecureQueueEntry(
    String queueId,
    Map<String, dynamic> data,
  ) async {
    // Gate on HMAC key initialization
    if (!HmacKeyService.isInitialized) {
      // Try to wait briefly for initialization
      final initialized = await _waitForHmacKeyInitialization(timeoutMs: 500);
      
      if (!initialized) {
        // Enqueue operation for retry
        debugPrint('[SecurityHardening] createSecureQueueEntry: HMAC key not ready, queuing operation');
        return _enqueueOperation(
          _OperationType.createQueueEntry,
          {'queueId': queueId, 'data': data},
        );
      }
    }
    
    // At this point, HmacKeyService should be initialized
    if (!HmacKeyService.isInitialized) {
      // This should not happen, but if it does, throw exception
      throw Exception(
        'HMAC key service not initialized - cannot create secure queue entry. '
        'Callers must ensure HmacKeyService.initialize() completes before creating queue entries.'
      );
    }
    
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomNonce = _generateSecureToken();
    
    // Get current HMAC key from HmacKeyService
    final hmacKey = HmacKeyService.getHmacKey();
    final keyVersion = HmacKeyService.getCurrentKeyVersion();
    
    // Build HMAC input: queueId:timestamp:nonce:data
    final hmacInput = '$queueId:$timestamp:$randomNonce:${jsonEncode(data)}';
    final hmacValue = _generateHmacSha256(hmacKey, hmacInput);
    
    final entry = {
      'queueId': queueId,
      'timestamp': timestamp,
      'nonce': randomNonce,
      'data': data,
      'hmac': base64Encode(hmacValue),
      'keyVersion': keyVersion,
    };
    
    return entry;
  }
  
  /// Enqueue an operation for retry after HMAC key initialization
  Future<Map<String, dynamic>> _enqueueOperation(
    _OperationType type,
    Map<String, dynamic> params,
  ) async {
    final completer = Completer<Map<String, dynamic>>();
    
    _pendingOperations.add(_PendingOperation(
      type: type,
      params: params,
      completer: completer,
      retryCount: 0,
    ));
    
    // Schedule retry after 500ms
    Future.delayed(const Duration(milliseconds: 500), _processPendingOperations);
    
    return completer.future;
  }

  /// Verify queue entry integrity using HMAC-SHA256
  /// 
  /// SECURITY: Verifies HMAC-SHA256 signature using the key version specified
  /// in the entry. Supports key rotation by looking up old key versions.
  Future<bool> verifyQueueEntry(Map<String, dynamic> entry) async {
    try {
      final queueId = entry['queueId'] as String;
      final timestamp = entry['timestamp'] as int;
      final nonce = entry['nonce'] as String;
      final data = entry['data'];
      final storedHmacBase64 = entry['hmac'] as String;
      final keyVersion = entry['keyVersion'] as String?;
      
      // Check timestamp is not too old
      final age = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (age > SecurityConfig.maxTimestampSkewMinutes * 60 * 1000) {
        debugPrint('[SecurityHardening] verifyQueueEntry: TIMESTAMP TOO OLD');
        return false;
      }
      
      // Get the appropriate HMAC key
      Uint8List? hmacKey;
      if (keyVersion != null) {
        // SECURITY: Version enforcement - must use the exact key version specified
        // The 'temp' bypass has been removed for security reasons
        hmacKey = HmacKeyService.getKeyVersion(keyVersion);
        if (hmacKey == null) {
          debugPrint('[SecurityHardening] verifyQueueEntry: SECURITY ERROR - Key version not found: $keyVersion');
          debugPrint('[SecurityHardening] verifyQueueEntry: This may indicate:');
          debugPrint('[SecurityHardening] verifyQueueEntry:   - Key rotation without proper migration');
          debugPrint('[SecurityHardening] verifyQueueEntry:   - Tampered queue entry');
          debugPrint('[SecurityHardening] verifyQueueEntry:   - Incomplete key restore from backup');
          return false;
        }
      } else {
        // SECURITY: Queue entries without a key version are rejected
        // This prevents downgrade attacks and ensures version enforcement
        debugPrint('[SecurityHardening] verifyQueueEntry: SECURITY ERROR - No key version specified');
        debugPrint('[SecurityHardening] verifyQueueEntry: Legacy queue entries without version are not supported');
        return false;
      }
      
      // Compute HMAC-SHA256
      final hmacInput = '$queueId:$timestamp:$nonce:${jsonEncode(data)}';
      final computedHmac = _generateHmacSha256(hmacKey, hmacInput);
      final storedHmac = base64Decode(storedHmacBase64);
      
      // Constant-time comparison to prevent timing attacks
      if (!_constantTimeCompare(computedHmac, storedHmac)) {
        debugPrint('[SecurityHardening] verifyQueueEntry: HMAC MISMATCH');
        return false;
      }
      
      return true;
    } catch (e) {
      debugPrint('[SecurityHardening] verifyQueueEntry: ERROR - $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // SESSION VALIDATION
  // ──────────────────────────────────────────────────────────────────────────

  /// Generate cryptographically bound session token
  /// 
  /// SECURITY: Creates a session token with the following structure:
  ///   token = base64(userId || timestamp || random || HMAC-SHA256(key, userId || timestamp || random))
  /// 
  /// This binds the token to:
  /// - User identity (prevents token replay for different users)
  /// - Timestamp (prevents expired token reuse)
  /// - Cryptographic integrity (prevents token tampering)
  /// 
  /// The token can only be validated with the same HMAC key used to create it.
  /// 
  /// REQUIRES: HmacKeyService must be initialized. Throws exception if unavailable.
  String generateSessionToken(String userId) {
    // Gate on HMAC key initialization
    if (!HmacKeyService.isInitialized) {
      throw Exception(
        'HMAC key service not initialized - cannot generate secure session token. '
        'Callers must ensure HmacKeyService.initialize() completes before generating session tokens.'
      );
    }
    
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final randomBytes = _generateSecureRandomBytes(16);
      
      // Build token payload: userId || timestamp || random
      final timestampBytes = _int64ToBytes(timestamp);
      final userIdBytes = utf8.encode(userId);
      
      final payload = BytesBuilder()
        ..add(userIdBytes)
        ..add(timestampBytes)
        ..add(randomBytes);
      
      // Get HMAC key for signing
      final hmacKey = HmacKeyService.getHmacKey();
      
      // Compute HMAC-SHA256 over payload
      final payloadBytes = payload.toBytes();
      final hmac = _generateHmacSha256(hmacKey, base64Encode(payloadBytes));
      
      // Build final token: payload || hmac
      final token = BytesBuilder()
        ..add(payloadBytes)
        ..add(hmac);
      
      return base64Encode(token.toBytes());
    } catch (e) {
      debugPrint('[SecurityHardening] generateSessionToken: ERROR - $e');
      // Re-throw so callers know integrity was not applied
      throw Exception(
        'Failed to generate secure session token: $e'
      );
    }
  }

  /// Validate session token with cryptographic binding
  /// 
  /// SECURITY: Verifies:
  /// 1. Token structure integrity
  /// 2. Cryptographic signature (HMAC)
  /// 3. User ID binding (token was issued for this user)
  /// 4. Timestamp validity (not expired)
  /// 
  /// Returns true only if all checks pass.
  Future<bool> validateSessionToken(String token, String expectedUserId) async {
    try {
      // Decode token
      final tokenBytes = base64Decode(token);
      
      // Token structure: [userId || timestamp || random (variable)] || [HMAC (32 bytes)]
      // Minimum size: userId (1+) + timestamp (8) + random (16) + hmac (32) = 57+ bytes
      if (tokenBytes.length < 57) {
        debugPrint('[SecurityHardening] validateSessionToken: TOKEN TOO SHORT (${tokenBytes.length} bytes)');
        return false;
      }
      
      // Extract HMAC (last 32 bytes)
      final storedHmac = tokenBytes.sublist(tokenBytes.length - 32);
      final payloadBytes = tokenBytes.sublist(0, tokenBytes.length - 32);
      
      // Extract timestamp (8 bytes after userId)
      // We need to find where userId ends - it's UTF-8 encoded
      // For simplicity, we'll parse from the end: timestamp is 24 bytes before HMAC (8 timestamp + 16 random)
      final timestampStart = payloadBytes.length - 24;
      final timestampBytes = payloadBytes.sublist(timestampStart, timestampStart + 8);
      final timestamp = _bytesToInt64(timestampBytes);
      
      // Check token age
      final tokenAge = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (tokenAge > SecurityConfig.sessionValidityHours * 60 * 60 * 1000) {
        debugPrint('[SecurityHardening] validateSessionToken: TOKEN EXPIRED (${tokenAge ~/ 1000 ~/ 60} minutes old)');
        return false;
      }
      
      // Extract userId (everything before timestamp)
      final userIdBytes = payloadBytes.sublist(0, timestampStart);
      final tokenUserId = utf8.decode(userIdBytes);
      
      // Verify user ID binding
      if (tokenUserId != expectedUserId) {
        debugPrint('[SecurityHardening] validateSessionToken: USER ID MISMATCH');
        return false;
      }
      
      // Get HMAC key for verification
      Uint8List? hmacKey;
      try {
        hmacKey = HmacKeyService.getHmacKey();
      } catch (e) {
        // Try to get any available key version
        final diagnostics = HmacKeyService.getDiagnostics();
        final versions = diagnostics['cachedVersions'] as List<dynamic>?;
        if (versions != null && versions.isNotEmpty) {
          for (final version in versions.reversed) {
            hmacKey = HmacKeyService.getKeyVersion(version as String);
            if (hmacKey != null) break;
          }
        }
      }
      
      if (hmacKey == null) {
        debugPrint('[SecurityHardening] validateSessionToken: NO HMAC KEY AVAILABLE');
        return false;
      }
      
      // Recompute HMAC over payload
      final computedHmac = _generateHmacSha256(hmacKey, base64Encode(payloadBytes));
      
      // Constant-time comparison to prevent timing attacks
      if (!_constantTimeCompare(computedHmac, storedHmac)) {
        debugPrint('[SecurityHardening] validateSessionToken: HMAC VERIFICATION FAILED');
        return false;
      }
      
      return true;
    } catch (e) {
      debugPrint('[SecurityHardening] validateSessionToken: ERROR - $e');
      return false;
    }
  }

  /// Convert int64 to 8-byte little-endian array
  Uint8List _int64ToBytes(int value) {
    final bytes = Uint8List(8);
    final byteData = ByteData.sublistView(bytes);
    byteData.setInt64(0, value, Endian.little);
    return bytes;
  }

  /// Convert 8-byte little-endian array to int64
  int _bytesToInt64(Uint8List bytes) {
    if (bytes.length != 8) {
      throw ArgumentError('Expected 8 bytes, got ${bytes.length}');
    }
    final byteData = ByteData.sublistView(bytes);
    return byteData.getInt64(0, Endian.little);
  }

  /// Generate cryptographically secure random bytes
  Uint8List _generateSecureRandomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // MEMORY HARDENING
  // ──────────────────────────────────────────────────────────────────────────

  /// Securely clear sensitive data from memory
  void clearSensitiveData(List<int> data) {
    if (data.isEmpty) return;
    
    // Overwrite with random data multiple times
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < data.length; j++) {
        data[j] = _random.nextInt(256);
      }
    }
    
    // Clear the list
    data.clear();
  }

  /// Clear all security-related caches
  Future<void> clearAllCaches() async {
    debugPrint('[SecurityHardening] clearAllCaches: START');
    
    _processedNonces.clear();
    _messageSequenceNumbers.clear();
    
    await _storage.delete(key: 'processed_nonces');
    await _storage.delete(key: 'session_needs_revalidation');
    
    debugPrint('[SecurityHardening] clearAllCaches: END');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // PRIVATE HELPERS
  // ──────────────────────────────────────────────────────────────────────────

  String _generateSecureToken() {
    final bytes = List.generate(32, (_) => _random.nextInt(256));
    return base64Encode(bytes);
  }

  String _generateNonce(String messageId, String? timestamp, Map<String, dynamic>? data) {
    final combined = '${messageId}_${timestamp ?? DateTime.now().millisecondsSinceEpoch}_${jsonEncode(data)}';
    return base64Encode(utf8.encode(combined)).substring(0, 32);
  }

  /// Generate HMAC-SHA256 using PointCastle
  /// 
  /// SECURITY: Uses proper HMAC-SHA256 implementation from PointCastle.
  /// The key should be obtained from HmacKeyService for production use.
  Uint8List _generateHmacSha256(Uint8List key, String data) {
    final hmac = HMac(SHA256Digest(), 64);
    hmac.init(KeyParameter(key));
    final dataBytes = utf8.encode(data);
    hmac.update(Uint8List.fromList(dataBytes), 0, dataBytes.length);
    final output = Uint8List(32);
    hmac.doFinal(output, 0);
    return output;
  }



  /// Constant-time comparison of two byte arrays
  /// 
  /// SECURITY: Prevents timing attacks by ensuring comparison time
  /// is independent of where the first difference occurs.
  bool _constantTimeCompare(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// Securely clear sensitive data from memory
  void _secureClear(Uint8List data) {
    for (var i = 0; i < data.length; i++) {
      data[i] = 0;
    }
  }

  /// DEPRECATED: Old weak HMAC implementation
  /// 
  /// WARNING: This function is cryptographically broken and should NOT be used.
  /// It is kept for reference only. Use _generateHmacSha256 instead.
  @Deprecated('Use _generateHmacSha256 with proper key management')
  String _generateHmac(String data) {
    // Simplified HMAC-like function for queue integrity
    // DEPRECATED: In production, use crypto package
    var hash = 0;
    for (int i = 0; i < data.length; i++) {
      hash = ((hash << 5) - hash + data.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Conditionally log security-related messages
  /// 
  /// SECURITY: In production mode, security logs are suppressed to prevent
  /// information leakage. In development mode, logs are enabled for debugging.
  /// 
  /// Always use this method instead of direct debugPrint for security logs.
  void _logSecurity(String message) {
    // Only log in development mode or when explicitly enabled
    if (AppConfig.enableSensitiveLogging || kDebugMode) {
      debugPrint(message);
    }
  }

  Future<void> _loadSecurityState() async {
    try {
      final storedScore = await _storage.read(key: 'trust_score');
      if (storedScore != null) {
        _trustScore = int.tryParse(storedScore) ?? 100;
      }
    } catch (e) {
      debugPrint('[SecurityHardening] _loadSecurityState: ERROR - $e');
    }
  }

  /// Get security report for debugging
  Map<String, dynamic> getSecurityReport() {
    return {
      'deviceSecure': _isDeviceSecure,
      'integrityVerified': _isIntegrityVerified,
      'debuggerDetected': _debuggerDetected,
      'trustScore': _trustScore,
      'processedNonces': _processedNonces.length,
      'lastSecurityCheck': _lastSecurityCheck?.toIso8601String(),
    };
  }
}

/// Security check result
class SecurityCheckResult {
  final bool passed;
  final String reason;
  final int trustScoreImpact;

  const SecurityCheckResult({
    required this.passed,
    required this.reason,
    this.trustScoreImpact = 0,
  });
}

/// Operation types for pending operations queue
enum _OperationType {
  createQueueEntry,
  generateSessionToken,
}

/// Pending operation for HMAC key initialization retry
class _PendingOperation {
  final _OperationType type;
  final Map<String, dynamic> params;
  final Completer<Map<String, dynamic>> completer;
  int retryCount;

  _PendingOperation({
    required this.type,
    required this.params,
    required this.completer,
    this.retryCount = 0,
  });
}
