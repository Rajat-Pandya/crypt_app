import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Memoized decryption result
class DecryptResult {
  final String plaintext;
  final bool success;
  final String? error;
  final DateTime timestamp;

  DecryptResult.success(this.plaintext)
    : success = true,
      error = null,
      timestamp = DateTime.now();

  DecryptResult.failure(this.error)
    : success = false,
      plaintext = '🔒',
      timestamp = DateTime.now();

  bool get isStale => 
    DateTime.now().difference(timestamp).inMinutes > 30;
}

/// Failure cache entry with TTL tracking
class _FailureCacheEntry {
  final DecryptResult result;
  final DateTime failedAt;
  
  _FailureCacheEntry(this.result) : failedAt = DateTime.now();
  
  /// Check if failure is within TTL (5 minutes)
  bool get isWithinTTL => 
    DateTime.now().difference(failedAt) < const Duration(minutes: 5);
}

/// Centralized decryption memoization service to prevent:
/// - Duplicate decrypt attempts
/// - Rebuild storms
/// - Isolate job spam
class DecryptMemoizationService {
  static final DecryptMemoizationService _instance = DecryptMemoizationService._internal();
  factory DecryptMemoizationService() => _instance;
  DecryptMemoizationService._internal();

  // Completed decrypt results
  final Map<String, DecryptResult> _decryptCache = {};
  
  // In-progress decrypt operations (prevent duplicates)
  final Map<String, Future<String>> _inProgressDecrypts = {};
  
  // Failed decrypt cache with TTL (prevent repeated attempts)
  final Map<String, _FailureCacheEntry> _failureCache = {};
  final Set<String> _permanentFailures = {};
  
  // LRU tracking for cache eviction
  final LinkedHashMap<String, DecryptResult> _lruCache = LinkedHashMap();
  static const int _maxCacheSize = 100;
  
  // Stats for monitoring
  int _hitCount = 0;
  int _missCount = 0;
  int _duplicatePrevented = 0;

  // Logging
  static void _logDecrypt(String message) {
    assert(() {
      debugPrint('[DECRYPT] $message');
      return true;
    }());
  }

  static void _logPerf(String message) {
    assert(() {
      debugPrint('[PERF] $message');
      return true;
    }());
  }

  /// Get decrypted message with memoization.
  /// 
  /// Returns cached result if available, otherwise executes decrypt function.
  /// Prevents duplicate decrypts for the same message ID.
  Future<String> getDecryptedMessage(
    String messageId,
    Future<String> Function() decryptFunction, {
    bool allowRetry = false,
  }) async {
    // Check permanent failures first
    if (_permanentFailures.contains(messageId) && !allowRetry) {
      _logDecrypt('Message $messageId has permanent failure, skipping');
      _duplicatePrevented++;
      return '🔒';
    }

    // Check completed cache
    if (_decryptCache.containsKey(messageId)) {
      final cached = _decryptCache[messageId]!;
      if (!cached.isStale || cached.success) {
        _hitCount++;
        _logDecrypt('Cache hit for message $messageId');
        return cached.plaintext;
      }
      // Stale failure - remove and retry
      _decryptCache.remove(messageId);
    }

    // Check failure cache (temporary) with TTL
    if (_failureCache.containsKey(messageId) && !allowRetry) {
      final entry = _failureCache[messageId]!;
      // Check TTL - only return cached failure if within 5 minutes
      if (entry.isWithinTTL) {
        _logDecrypt('Using cached failure for message $messageId (TTL valid)');
        _duplicatePrevented++;
        return entry.result.plaintext;
      }
      // TTL expired - remove and allow retry
      _logDecrypt('Failure cache TTL expired for message $messageId, allowing retry');
      _failureCache.remove(messageId);
    }

    // Check in-progress decrypts (prevent duplicates)
    if (_inProgressDecrypts.containsKey(messageId)) {
      _logDecrypt('Waiting for in-progress decrypt of message $messageId');
      _duplicatePrevented++;
      return await _inProgressDecrypts[messageId]!;
    }

    _missCount++;
    _logDecrypt('Starting decrypt for message $messageId');

    // Execute decrypt and track
    final decryptFuture = _executeDecrypt(messageId, decryptFunction);
    _inProgressDecrypts[messageId] = decryptFuture;

    try {
      final result = await decryptFuture;
      _cacheResult(messageId, DecryptResult.success(result));
      return result;
    } finally {
      _inProgressDecrypts.remove(messageId);
    }
  }

  /// Execute decrypt with error handling
  Future<String> _executeDecrypt(
    String messageId,
    Future<String> Function() decryptFunction,
  ) async {
    final startTime = DateTime.now();
    
    try {
      final result = await decryptFunction();
      
      final duration = DateTime.now().difference(startTime);
      _logPerf('Decrypt completed for $messageId in ${duration.inMilliseconds}ms');
      
      return result;
    } catch (e) {
      _logDecrypt('Decrypt failed for $messageId: ${e.runtimeType}');
      
      // Cache the failure temporarily with TTL
      final failure = DecryptResult.failure(e.toString());
      _failureCache[messageId] = _FailureCacheEntry(failure);
      
      // Check if should be permanent
      if (_isPermanentFailure(e)) {
        _permanentFailures.add(messageId);
        _logDecrypt('Marked as permanent failure: $messageId');
      }
      
      rethrow;
    }
  }

  /// Cache successful result with LRU eviction
  void _cacheResult(String messageId, DecryptResult result) {
    // Remove old entry if exists
    if (_lruCache.containsKey(messageId)) {
      _lruCache.remove(messageId);
    }

    // Add to LRU
    _lruCache[messageId] = result;
    _decryptCache[messageId] = result;

    // Evict oldest if over limit
    while (_lruCache.length > _maxCacheSize) {
      final oldest = _lruCache.keys.first;
      _lruCache.remove(oldest);
      _decryptCache.remove(oldest);
      _logPerf('Evicted oldest decrypt cache entry: $oldest');
    }
  }

  /// Check if error is permanent (shouldn't retry)
  bool _isPermanentFailure(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return 
      errorStr.contains('key mismatch') ||
      errorStr.contains('key version') ||
      errorStr.contains('invalid key') ||
      errorStr.contains('corrupted') ||
      errorStr.contains('wrong key');
  }

  /// Preload decrypt results for a list of message IDs
  Future<void> preloadDecrypts(
    List<String> messageIds,
    Future<String?> Function(String) decryptLoader,
  ) async {
    _logDecrypt('Preloading ${messageIds.length} decrypts');
    
    // Process in batches to avoid overwhelming
    final futures = <Future>[];
    for (final messageId in messageIds) {
      if (!_decryptCache.containsKey(messageId) && 
          !_inProgressDecrypts.containsKey(messageId)) {
        futures.add(
          getDecryptedMessage(messageId, () async {
            final result = await decryptLoader(messageId);
            return result ?? '🔒';
          }),
        );
      }
    }

    // Wait for all with timeout
    await Future.wait(futures).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _logDecrypt('Preload timeout - some decrypts may be pending');
        return [];
      },
    );
  }

  /// Invalidate cached result (e.g., after key rotation)
  void invalidate(String messageId) {
    _decryptCache.remove(messageId);
    _failureCache.remove(messageId);
    _lruCache.remove(messageId);
    _permanentFailures.remove(messageId);
    _logDecrypt('Invalidated cache for message $messageId');
  }
  
  /// Clear failure cache on key rotation - retries all failed messages with new key
  void clearFailureCacheOnKeyRotation() {
    final failureCount = _failureCache.length;
    final permanentCount = _permanentFailures.length;
    
    _failureCache.clear();
    _permanentFailures.clear();
    
    _logDecrypt('Cleared failure cache on key rotation: $failureCount failures cleared, $permanentCount permanent failures cleared');
  }

  /// Clear all caches
  void clearCache() {
    _decryptCache.clear();
    _failureCache.clear();
    _lruCache.clear();
    _permanentFailures.clear();
    _inProgressDecrypts.clear();
    _hitCount = 0;
    _missCount = 0;
    _duplicatePrevented = 0;
    _logDecrypt('Cleared all decrypt caches');
  }

  /// Get cache statistics
  Map<String, dynamic> getStats() {
    return {
      'cacheSize': _decryptCache.length,
      'failureCacheSize': _failureCache.length,
      'permanentFailures': _permanentFailures.length,
      'inProgress': _inProgressDecrypts.length,
      'hitCount': _hitCount,
      'missCount': _missCount,
      'duplicatePrevented': _duplicatePrevented,
      'hitRate': _hitCount + _missCount > 0 
          ? '${(_hitCount / (_hitCount + _missCount) * 100).toStringAsFixed(1)}%'
          : 'N/A',
    };
  }

  /// Check if message is currently being decrypted
  bool isDecryptInProgress(String messageId) {
    return _inProgressDecrypts.containsKey(messageId);
  }

  /// Check if message has cached result
  bool hasCachedResult(String messageId) {
    return _decryptCache.containsKey(messageId) ||
           _failureCache.containsKey(messageId);
  }

  // ==========================================================================
  // API FOR UnifiedDecryptService
  // ==========================================================================

  /// Get cached result or null.
  DecryptResult? getResult(String messageId) {
    if (_decryptCache.containsKey(messageId)) {
      return _decryptCache[messageId];
    }
    if (_failureCache.containsKey(messageId)) {
      return _failureCache[messageId]!.result;
    }
    return null;
  }

  /// Check if currently decrypting.
  bool isDecrypting(String messageId) {
    return _inProgressDecrypts.containsKey(messageId);
  }

  /// Wait for an in-progress decrypt to complete.
  Future<DecryptResult> waitForResult(
    String messageId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_inProgressDecrypts.containsKey(messageId)) {
      try {
        final plaintext = await _inProgressDecrypts[messageId]!.timeout(timeout);
        return DecryptResult.success(plaintext);
      } catch (e) {
        return DecryptResult.failure(e.toString());
      }
    }
    return getResult(messageId) ?? DecryptResult.failure('No result available');
  }

  /// Mark a message as being decrypted.
  void markDecrypting(String messageId) {
    // Already tracked via _inProgressDecrypts in getDecryptedMessage
  }

  /// Mark a message as done decrypting.
  void markDone(String messageId) {
    _inProgressDecrypts.remove(messageId);
  }

  /// Cache a result directly.
  void cacheResult(String messageId, DecryptResult result) {
    _cacheResult(messageId, result);
  }

  /// Clear a specific result.
  void clearResult(String messageId) {
    invalidate(messageId);
  }

  /// Clear all results.
  void clearAll() {
    clearCache();
  }

  /// Current cache size.
  int get cacheSize => _decryptCache.length;
}
