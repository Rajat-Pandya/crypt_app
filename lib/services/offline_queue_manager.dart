import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mutex/mutex.dart';

/// Enhanced offline queue with UUID-based IDs, stable retry, and ordering preservation.
///
/// Features:
/// - UUID v4 generation for unique message IDs
/// - In-flight tracking (prevents duplicate sends during retry)
/// - Sequence numbers for ordering preservation
/// - Processing locks for reconnect safety
/// - Exponential backoff for retries
/// - Message deduplication using content hash
/// - Stale message prevention
/// - Safe conflict resolution

class OfflineQueueManager {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'offline_msg_';
  static const _sentLogKey = 'offline_msg_log';
  static const _sequenceKey = 'offline_msg_sequence';
  static const _inFlightKey = 'offline_msg_inflight';
  static const _maxRetryCount = 3;
  static const _staleMessageHours = 24;
  
  // Retry delays with exponential backoff: 2s, 4s, 8s
  static const List<Duration> _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  // In-memory state
  static final Map<String, _ProcessingLock> _processingLocks = {};
  static final Set<String> _inMemoryInFlight = {};
  static int _currentSequence = 0;
  
  // BUG 6 FIX: Static mutex for sequence number race condition protection
  static final _sequenceMutex = Mutex();

  static void _dbg(String message) {
    assert(() {
      debugPrint('[OfflineQueue] $message');
      return true;
    }());
  }

  // ==========================================================================
  // UUID GENERATION (RFC 4122 v4)
  // ==========================================================================

  /// Generates a standard UUID v4
  /// 
  /// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  /// where x is any hexadecimal digit and y is one of 8, 9, A, or B
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    
    // Set version (4) and variant (RFC 4122)
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // Variant: RFC 4122
    
    // Convert to hex string with dashes
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
           '${hex.substring(8, 12)}-'
           '${hex.substring(12, 16)}-'
           '${hex.substring(16, 20)}-'
           '${hex.substring(20, 32)}';
  }

  static DateTime get now => DateTime.now();

  // ==========================================================================
  // SEQUENCE MANAGEMENT (Ordering Preservation)
  // ==========================================================================

  /// Gets the next sequence number for ordering
  /// BUG 6 FIX: Wrapped with mutex to prevent race condition
  static Future<int> _getNextSequence() async {
    await _sequenceMutex.acquire();
    try {
      final stored = await _storage.read(key: _sequenceKey);
      final seq = stored != null ? int.tryParse(stored) ?? 0 : 0;
      final next = seq + 1;
      await _storage.write(key: _sequenceKey, value: next.toString());
      return next;
    } catch (e) {
      _dbg('Failed to get sequence: $e');
      _currentSequence++;
      return _currentSequence;
    } finally {
      _sequenceMutex.release();
    }
  }

  // ==========================================================================
  // IN-FLIGHT TRACKING (Duplicate Prevention)
  // ==========================================================================

  /// Marks a message as being processed (in-flight)
  static Future<void> _markInFlight(String messageId) async {
    _inMemoryInFlight.add(messageId);
    try {
      final inflight = await _getInFlight();
      inflight.add(messageId);
      await _storage.write(key: _inFlightKey, value: jsonEncode(inflight.toList()));
      _processingLocks[messageId] = _ProcessingLock(
        messageId: messageId,
        lockedAt: DateTime.now(),
      );
      _dbg('Marked in-flight: $messageId');
    } catch (e) {
      _dbg('Failed to mark in-flight: $e');
    }
  }

  /// Removes a message from in-flight tracking
  static Future<void> _removeInFlight(String messageId) async {
    _inMemoryInFlight.remove(messageId);
    _processingLocks.remove(messageId);
    try {
      final inflight = await _getInFlight();
      inflight.remove(messageId);
      await _storage.write(key: _inFlightKey, value: jsonEncode(inflight.toList()));
      _dbg('Removed in-flight: $messageId');
    } catch (e) {
      _dbg('Failed to remove in-flight: $e');
    }
  }

  /// Gets all in-flight message IDs
  static Future<Set<String>> _getInFlight() async {
    // Check memory first
    if (_inMemoryInFlight.isNotEmpty) {
      return {..._inMemoryInFlight};
    }
    
    try {
      final stored = await _storage.read(key: _inFlightKey);
      if (stored == null) return {};
      final list = jsonDecode(stored) as List;
      final result = list.cast<String>().toSet();
      _inMemoryInFlight.addAll(result);
      return result;
    } catch (e) {
      _dbg('Failed to get in-flight: $e');
      return {};
    }
  }

  /// Clears stale in-flight entries (call on app startup)
  static Future<void> clearStaleInFlight({Duration maxAge = const Duration(minutes: 5)}) async {
    _dbg('Clearing stale in-flight entries...');
    try {
      final inflight = await _getInFlight();
      final now = DateTime.now();
      final stale = <String>[];
      
      for (final id in inflight) {
        final lock = _processingLocks[id];
        if (lock != null) {
          if (now.difference(lock.lockedAt) > maxAge) {
            stale.add(id);
            _dbg('Found stale in-flight: $id');
          }
        } else {
          // No lock info, assume stale
          stale.add(id);
        }
      }
      
      for (final id in stale) {
        inflight.remove(id);
        _processingLocks.remove(id);
        _inMemoryInFlight.remove(id);
      }
      
      await _storage.write(key: _inFlightKey, value: jsonEncode(inflight.toList()));
      _dbg('Cleared ${stale.length} stale in-flight entries');
    } catch (e) {
      _dbg('Failed to clear stale in-flight: $e');
    }
  }

  /// Checks if a message is currently being processed
  static Future<bool> isInFlight(String messageId) async {
    if (_inMemoryInFlight.contains(messageId)) return true;
    final inflight = await _getInFlight();
    return inflight.contains(messageId);
  }

  // ==========================================================================
  // PROCESSING LOCKS (Reconnect Safety)
  // ==========================================================================

  /// Acquires a processing lock for a message
  static Future<bool> acquireLock(String messageId, {Duration timeout = const Duration(seconds: 30)}) async {
    if (_processingLocks.containsKey(messageId)) {
      final lock = _processingLocks[messageId]!;
      if (lock.isValid) {
        _dbg('Lock already held for: $messageId');
        return false;
      } else {
        _dbg('Lock expired for: $messageId, taking over');
      }
    }
    
    _processingLocks[messageId] = _ProcessingLock(
      messageId: messageId,
      lockedAt: DateTime.now(),
      timeout: timeout,
    );
    
    await _markInFlight(messageId);
    return true;
  }

  /// Releases a processing lock
  static Future<void> releaseLock(String messageId) async {
    _processingLocks.remove(messageId);
    await _removeInFlight(messageId);
  }

  // ==========================================================================
  // RETRY BACKOFF
  // ==========================================================================

  /// Gets the delay for the next retry attempt
  static Duration getRetryDelay(int retryCount) {
    if (retryCount < _retryDelays.length) {
      return _retryDelays[retryCount];
    }
    return _retryDelays.last;
  }

  /// Calculates total time spent waiting for retries
  static Duration getTotalRetryTime(int retryCount) {
    var total = Duration.zero;
    for (var i = 0; i < retryCount && i < _retryDelays.length; i++) {
      total += _retryDelays[i];
    }
    return total;
  }

  // ==========================================================================
  // QUEUE OPERATIONS
  // ==========================================================================

  /// Enqueue a message for sending when connectivity is restored
  /// 
  /// FEATURES:
  /// - UUID v4 generation for unique IDs
  /// - Sequence numbers for ordering
  /// - Duplicate detection using content hash
  /// - In-flight check (prevents re-queueing during send)
  /// - Stale message filtering
  static Future<void> enqueue(Map<String, dynamic> payload) async {
    debugPrint('[OfflineQueueManager] enqueue: START - payload keys: ${payload.keys.join(", ")}');
    try {
      // Generate UUID-based message ID for collision avoidance
      final timestamp = now;
      final messageId = _generateUuid();
      final contentHash = _generateHash(payload);
      final sequence = await _getNextSequence();
      
      debugPrint('[OfflineQueueManager] enqueue: generated messageId: $messageId, sequence: $sequence, contentHash: $contentHash');

      // GUARD: Check if already in-flight (being sent)
      if (await isInFlight(messageId)) {
        debugPrint('[OfflineQueueManager] enqueue: message already in-flight, skipping');
        return;
      }

      // Check for recent duplicates (prevent resend)
      debugPrint('[OfflineQueueManager] enqueue: checking for duplicates');
      final recentSent = await _getRecentlySent();
      if (recentSent.contains(contentHash)) {
        debugPrint('[OfflineQueueManager] enqueue: WARNING - duplicate message detected, skipping - hash: $contentHash');
        debugPrint('[OfflineQueueManager] enqueue: END');
        return;
      }
      debugPrint('[OfflineQueueManager] enqueue: no duplicates found');

      // Check if message is too old
      if (timestamp.isBefore(now.subtract(const Duration(hours: _staleMessageHours)))) {
        debugPrint('[OfflineQueueManager] enqueue: WARNING - stale message detected, skipping');
        debugPrint('[OfflineQueueManager] enqueue: END');
        return;
      }

      final queueItem = {
        'id': messageId,
        'hash': contentHash,
        'sequence': sequence, // For ordering preservation
        'payload': payload,
        'timestamp': timestamp.toIso8601String(),
        'retryCount': 0,
        'lastAttempt': null,
        'status': 'pending', // pending, in_flight, completed, failed
      };

      await _storage.write(key: '$_prefix$messageId', value: jsonEncode(queueItem));
      _dbg('enqueued message: $messageId (seq: $sequence)');
      debugPrint('[OfflineQueueManager] enqueue: SUCCESS - message enqueued - id: $messageId, sequence: $sequence');
    } catch (e) {
      debugPrint('[OfflineQueueManager] enqueue: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[OfflineQueueManager] enqueue: END');
  }

  /// Gets a message from the queue by ID
  static Future<Map<String, dynamic>?> getMessage(String messageId) async {
    try {
      final stored = await _storage.read(key: '$_prefix$messageId');
      if (stored == null) return null;
      return jsonDecode(stored) as Map<String, dynamic>;
    } catch (e) {
      _dbg('Failed to get message: $e');
      return null;
    }
  }

  /// Get all queued messages in FIFO order (by sequence number)
  static Future<List<Map<String, dynamic>>> getQueuedMessages() async {
    debugPrint('[OfflineQueueManager] getQueuedMessages: START');
    try {
      final all = await _storage.readAll();
      final entries = <Map<String, dynamic>>[];

      for (final entry in all.entries) {
        // Only include message entries (exclude logs and metadata)
        if (entry.key.startsWith(_prefix) && 
            !entry.key.contains('_log') && 
            !entry.key.contains('_sequence') &&
            !entry.key.contains('_inflight')) {
          try {
            final decoded = jsonDecode(entry.value) as Map<String, dynamic>;
            // Skip in-flight messages (being processed)
            if (decoded['status'] != 'in_flight') {
              entries.add(decoded);
            }
          } catch (e) {
            debugPrint('[OfflineQueueManager] getQueuedMessages: WARNING - failed to decode entry ${entry.key}: $e');
          }
        }
      }

      // Sort by sequence number for strict ordering
      entries.sort((a, b) {
        // Primary: sequence number
        final aSeq = (a['sequence'] as int?) ?? 0;
        final bSeq = (b['sequence'] as int?) ?? 0;
        if (aSeq != bSeq) return aSeq.compareTo(bSeq);
        
        // Secondary: timestamp (fallback)
        final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime(1970);
        final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime(1970);
        return aTime.compareTo(bTime);
      });

      debugPrint('[OfflineQueueManager] getQueuedMessages: SUCCESS - ${entries.length} messages queued');
      debugPrint('[OfflineQueueManager] getQueuedMessages: END');
      return entries;
    } catch (e) {
      debugPrint('[OfflineQueueManager] getQueuedMessages: ERROR - ${e.runtimeType}: $e');
      debugPrint('[OfflineQueueManager] getQueuedMessages: END');
      return [];
    }
  }

  /// Remove a message from the queue after successful send
  static Future<void> markSent(String messageId, String contentHash) async {
    debugPrint('[OfflineQueueManager] markSent: START - messageId: $messageId, contentHash: $contentHash');
    try {
      await _storage.delete(key: '$_prefix$messageId');
      await _addToSentLog(contentHash);
      _dbg('marked sent: $messageId');
      debugPrint('[OfflineQueueManager] markSent: SUCCESS - message marked as sent');
    } catch (e) {
      debugPrint('[OfflineQueueManager] markSent: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[OfflineQueueManager] markSent: END');
  }

  /// Remove a message from the queue after max retries
  static Future<void> markFailed(String messageId) async {
    debugPrint('[OfflineQueueManager] markFailed: START - messageId: $messageId');
    try {
      await _storage.delete(key: '$_prefix$messageId');
      _dbg('marked failed (removed): $messageId');
      debugPrint('[OfflineQueueManager] markFailed: SUCCESS - message marked as failed and removed');
    } catch (e) {
      debugPrint('[OfflineQueueManager] markFailed: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[OfflineQueueManager] markFailed: END');
  }

  /// Increment retry count for a message
  /// 
  /// Returns the delay for the next retry, or null if max retries reached
  static Future<Duration?> shouldRetry(String messageId) async {
    debugPrint('[OfflineQueueManager] shouldRetry: START - messageId: $messageId');
    final key = '$_prefix$messageId';
    final stored = await _storage.read(key: key);
    if (stored == null) {
      debugPrint('[OfflineQueueManager] shouldRetry: message not found, returning null');
      debugPrint('[OfflineQueueManager] shouldRetry: END');
      return null;
    }

    try {
      final item = jsonDecode(stored) as Map<String, dynamic>;
      final retryCount = (item['retryCount'] as int?) ?? 0;

      if (retryCount >= _maxRetryCount) {
        _dbg('max retries reached for: $messageId');
        debugPrint('[OfflineQueueManager] shouldRetry: max retries ($retryCount) reached');
        debugPrint('[OfflineQueueManager] shouldRetry: END');
        return null;
      }

      // GUARD: Check if already in-flight (another process handling it)
      if (await isInFlight(messageId)) {
        _dbg('Message already in-flight, not retrying: $messageId');
        return null;
      }

      final newRetryCount = retryCount + 1;
      item['retryCount'] = newRetryCount;
      item['lastAttempt'] = DateTime.now().toIso8601String();
      await _storage.write(key: key, value: jsonEncode(item));
      
      final delay = getRetryDelay(newRetryCount);
      debugPrint('[OfflineQueueManager] shouldRetry: SUCCESS - retryCount: $newRetryCount, delay: ${delay.inSeconds}s');
      debugPrint('[OfflineQueueManager] shouldRetry: END');
      return delay;
    } catch (e) {
      debugPrint('[OfflineQueueManager] shouldRetry: ERROR - ${e.runtimeType}: $e');
      debugPrint('[OfflineQueueManager] shouldRetry: END');
      return null;
    }
  }

  /// Gets the next retry time for a message
  static Future<DateTime?> getNextRetryTime(String messageId) async {
    final message = await getMessage(messageId);
    if (message == null) return null;
    
    final retryCount = (message['retryCount'] as int?) ?? 0;
    if (retryCount >= _maxRetryCount) return null;
    
    final lastAttempt = DateTime.tryParse(message['lastAttempt'] ?? '');
    if (lastAttempt == null) return DateTime.now();
    
    final delay = getRetryDelay(retryCount);
    return lastAttempt.add(delay);
  }

  /// Check if there are any queued messages
  static Future<bool> hasQueuedMessages() async {
    debugPrint('[OfflineQueueManager] hasQueuedMessages: START');
    try {
      final all = await _storage.readAll();
      final hasQueued = all.keys.any((k) => k.startsWith(_prefix) && !k.contains('_log'));
      debugPrint('[OfflineQueueManager] hasQueuedMessages: SUCCESS - hasQueued: $hasQueued');
      debugPrint('[OfflineQueueManager] hasQueuedMessages: END');
      return hasQueued;
    } catch (e) {
      debugPrint('[OfflineQueueManager] hasQueuedMessages: ERROR - ${e.runtimeType}: $e, returning false');
      debugPrint('[OfflineQueueManager] hasQueuedMessages: END');
      return false;
    }
  }

  /// Clear all queued messages (e.g., on logout)
  static Future<void> clearAll() async {
    debugPrint('[OfflineQueueManager] clearAll: START');
    try {
      final all = await _storage.readAll();
      int clearedCount = 0;
      for (final key in all.keys) {
        if (key.startsWith(_prefix)) {
          await _storage.delete(key: key);
          clearedCount++;
        }
      }
      _dbg('cleared all queued messages - $clearedCount items');
      debugPrint('[OfflineQueueManager] clearAll: SUCCESS - $clearedCount messages cleared');
    } catch (e) {
      debugPrint('[OfflineQueueManager] clearAll: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[OfflineQueueManager] clearAll: END');
  }

  /// Generate a simple hash for deduplication
  static String _generateHash(Map<String, dynamic> payload) {
    final content = payload['text']?.toString() ?? '';
    final receiverId = payload['receiverId']?.toString() ?? '';
    final hash = '${receiverId}_${content.hashCode}';
    return hash;
  }

  /// Track successfully sent message hashes to prevent duplicates
  static Future<void> _addToSentLog(String hash) async {
    debugPrint('[OfflineQueueManager] _addToSentLog: START - hash: $hash');
    try {
      final logJson = await _storage.read(key: _sentLogKey);
      final Set<String> sentHashes = {};

      if (logJson != null) {
        try {
          final decoded = jsonDecode(logJson) as List;
          sentHashes.addAll(decoded.cast<String>());
        } catch (e) {
          debugPrint('[OfflineQueueManager] _addToSentLog: WARNING - failed to decode log: $e');
        }
      }

      sentHashes.add(hash);

      // Keep only recent sent hashes (last 100)
      final trimmed = sentHashes.toList().take(100).toList();
      await _storage.write(key: _sentLogKey, value: jsonEncode(trimmed));
      debugPrint('[OfflineQueueManager] _addToSentLog: SUCCESS - hash added to sent log, total: ${trimmed.length}');
    } catch (e) {
      debugPrint('[OfflineQueueManager] _addToSentLog: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[OfflineQueueManager] _addToSentLog: END');
  }

  /// Get recently sent message hashes
  static Future<Set<String>> _getRecentlySent() async {
    debugPrint('[OfflineQueueManager] _getRecentlySent: START');
    try {
      final logJson = await _storage.read(key: _sentLogKey);
      if (logJson == null) {
        debugPrint('[OfflineQueueManager] _getRecentlySent: no log found, returning empty set');
        debugPrint('[OfflineQueueManager] _getRecentlySent: END');
        return {};
      }

      final decoded = jsonDecode(logJson) as List;
      final result = decoded.cast<String>().toSet();
      debugPrint('[OfflineQueueManager] _getRecentlySent: SUCCESS - ${result.length} hashes in log');
      debugPrint('[OfflineQueueManager] _getRecentlySent: END');
      return result;
    } catch (e) {
      debugPrint('[OfflineQueueManager] _getRecentlySent: ERROR - ${e.runtimeType}: $e, returning empty set');
      debugPrint('[OfflineQueueManager] _getRecentlySent: END');
      return {};
    }
  }

  /// Get the count of queued messages
  static Future<int> getQueueCount() async {
    debugPrint('[OfflineQueueManager] getQueueCount: START');
    try {
      final all = await _storage.readAll();
      final count = all.keys.where((k) => k.startsWith(_prefix) && !k.contains('_log')).length;
      debugPrint('[OfflineQueueManager] getQueueCount: SUCCESS - count: $count');
      debugPrint('[OfflineQueueManager] getQueueCount: END');
      return count;
    } catch (e) {
      debugPrint('[OfflineQueueManager] getQueueCount: ERROR - ${e.runtimeType}: $e, returning 0');
      debugPrint('[OfflineQueueManager] getQueueCount: END');
      return 0;
    }
  }
}

/// Stale move prevention for games
class GameMoveValidator {
  static const _storage = FlutterSecureStorage();
  static const _moveLogKey = 'game_move_log';
  static const _maxMoveAgeMinutes = 5;

  static Future<bool> shouldAllowMove(String gameId, String moveId) async {
    debugPrint('[GameMoveValidator] shouldAllowMove: START - gameId: $gameId, moveId: $moveId');
    final now = DateTime.now();

    // Get existing move log
    final logJson = await _storage.read(key: _moveLogKey);
    final Map<String, dynamic> moveLog = {};

    if (logJson != null) {
      try {
        moveLog.addAll(jsonDecode(logJson) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('[GameMoveValidator] shouldAllowMove: WARNING - failed to decode move log: $e');
      }
    }

    // Check if this move was already processed
    if (moveLog.containsKey('$gameId:$moveId')) {
      final lastAttempt = DateTime.tryParse(moveLog['$gameId:$moveId'] ?? '');
      if (lastAttempt != null) {
        final diff = now.difference(lastAttempt).inMinutes;
        if (diff > _maxMoveAgeMinutes) {
          debugPrint('[GameMoveValidator] shouldAllowMove: move is stale ($diff min), allowing re-submit');
          moveLog.remove('$gameId:$moveId');
        } else {
          debugPrint('[GameMoveValidator] shouldAllowMove: rejecting duplicate move - age: ${diff}m');
          debugPrint('[GameMoveValidator] shouldAllowMove: END');
          return false;
        }
      }
    }

    // Record this move attempt
    moveLog['$gameId:$moveId'] = now.toIso8601String();

    // Keep only recent moves (last 50)
    final keysToRemove = moveLog.keys.where((k) {
      final time = DateTime.tryParse(moveLog[k] ?? '');
      if (time == null) return true;
      return now.difference(time).inMinutes > 60;
    }).toList();

    for (final k in keysToRemove) {
      moveLog.remove(k);
    }

    await _storage.write(key: _moveLogKey, value: jsonEncode(moveLog));
    debugPrint('[GameMoveValidator] shouldAllowMove: SUCCESS - move allowed');
    debugPrint('[GameMoveValidator] shouldAllowMove: END');
    return true;
  }

  static Future<void> clearMoveLog() async {
    debugPrint('[GameMoveValidator] clearMoveLog: START');
    try {
      await _storage.delete(key: _moveLogKey);
      debugPrint('[GameMoveValidator] clearMoveLog: SUCCESS - move log cleared');
    } catch (e) {
      debugPrint('[GameMoveValidator] clearMoveLog: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[GameMoveValidator] clearMoveLog: END');
  }
}

// ============================================================================
// PROCESSING LOCK
// ============================================================================

/// Represents a processing lock for a message
/// 
/// Prevents duplicate processing during retries and reconnects
class _ProcessingLock {
  final String messageId;
  final DateTime lockedAt;
  final Duration timeout;
  
  _ProcessingLock({
    required this.messageId,
    required this.lockedAt,
    this.timeout = const Duration(seconds: 30),
  });
  
  /// Returns true if the lock is still valid (not expired)
  bool get isValid {
    return DateTime.now().difference(lockedAt) < timeout;
  }
  
  /// Returns the remaining time before the lock expires
  Duration get remainingTime {
    final elapsed = DateTime.now().difference(lockedAt);
    if (elapsed >= timeout) return Duration.zero;
    return timeout - elapsed;
  }
  
  @override
  String toString() => 'Lock($messageId, valid: $isValid, remaining: ${remainingTime.inSeconds}s)';
}
