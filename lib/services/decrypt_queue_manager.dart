import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Centralized decrypt queue manager to prevent rebuild storms.
/// 
/// Features:
/// - Max 2 concurrent decrypts
/// - FIFO queue with deduplication by messageId
/// - Proper cancellation of disposed tasks
/// - No build-phase decrypt scheduling
/// 
/// Usage:
/// ```dart
/// final manager = DecryptQueueManager();
/// final result = await manager.queueDecrypt(
///   messageId: doc.id,
///   decryptFn: () => _decryptMessage(data),
/// );
/// ```
class DecryptQueueManager {
  static final DecryptQueueManager _instance = DecryptQueueManager._internal();
  factory DecryptQueueManager() => _instance;
  DecryptQueueManager._internal();

  // Configuration
  static const int _maxConcurrentDecrypts = 2;
  static const Duration _dedupeWindow = Duration(seconds: 30);
  
  // Queue state
  final Queue<_DecryptTask> _queue = Queue<_DecryptTask>();
  final Map<String, _DecryptTask> _activeTasks = {};
  final Map<String, DateTime> _recentlyCompleted = {};
  final Set<String> _pendingMessageIds = {};
  
  int get activeCount => _activeTasks.length;
  int get queueLength => _queue.length;
  bool get hasCapacity => _activeTasks.length < _maxConcurrentDecrypts;
  
  // Stream controller for decrypt completion notifications
  final _completionController = StreamController<String>.broadcast();
  Stream<String> get onDecryptComplete => _completionController.stream;
  
  /// Queue a decrypt operation.
  /// 
  /// If the same messageId is already queued or active, returns the existing future.
  /// Otherwise, creates a new task and processes the queue.
  Future<String> queueDecrypt({
    required String messageId,
    required Future<String> Function() decryptFn,
    Duration? timeout,
  }) {
    // Check if already recently completed (dedupe)
    final recentlyCompleted = _recentlyCompleted[messageId];
    if (recentlyCompleted != null) {
      final elapsed = DateTime.now().difference(recentlyCompleted);
      if (elapsed < _dedupeWindow) {
        if (kDebugMode) {
          debugPrint('[DecryptQueueManager] Deduplicating $messageId (${elapsed.inSeconds}s ago)');
        }
        // Return cached result from storage (caller should check cache first)
        return Future.value(''); // Empty indicates "check cache"
      }
    }
    
    // Check if already active
    if (_activeTasks.containsKey(messageId)) {
      if (kDebugMode) {
        debugPrint('[DecryptQueueManager] Reusing active task for $messageId');
      }
      return _activeTasks[messageId]!.future;
    }
    
    // Check if already queued
    final existingQueued = _queue.where((t) => t.messageId == messageId).firstOrNull;
    if (existingQueued != null) {
      if (kDebugMode) {
        debugPrint('[DecryptQueueManager] Reusing queued task for $messageId');
      }
      return existingQueued.future;
    }
    
    // Create new task
    final task = _DecryptTask(
      messageId: messageId,
      decryptFn: decryptFn,
      timeout: timeout ?? const Duration(seconds: 30),
    );
    
    _pendingMessageIds.add(messageId);
    _queue.add(task);
    
    if (kDebugMode) {
      debugPrint('[DecryptQueueManager] Queued $messageId (queue: ${_queue.length}, active: ${_activeTasks.length})');
    }
    
    // Process queue
    _processQueue();
    
    return task.future;
  }
  
  /// Cancel all pending tasks for a message.
  void cancel(String messageId) {
    // Remove from queue if not started
    _queue.removeWhere((t) => t.messageId == messageId);
    _pendingMessageIds.remove(messageId);
    
    // Cancel if active
    if (_activeTasks.containsKey(messageId)) {
      _activeTasks[messageId]!.cancel();
      _activeTasks.remove(messageId);
    }
  }
  
  /// Cancel all tasks and clear queue.
  void dispose() {
    // Cancel all active tasks
    for (final task in _activeTasks.values) {
      task.cancel();
    }
    _activeTasks.clear();
    
    // Cancel all queued tasks
    for (final task in _queue) {
      task.cancel();
    }
    _queue.clear();
    
    _pendingMessageIds.clear();
    _recentlyCompleted.clear();
    _completionController.close();
  }
  
  void _processQueue() {
    while (hasCapacity && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _pendingMessageIds.remove(task.messageId);
      
      if (task.isCancelled) continue;
      
      _activeTasks[task.messageId] = task;
      
      if (kDebugMode) {
        debugPrint('[DecryptQueueManager] Starting ${task.messageId} (${_activeTasks.length}/$_maxConcurrentDecrypts active)');
      }
      
      task.execute().then((result) {
        _activeTasks.remove(task.messageId);
        _recentlyCompleted[task.messageId] = DateTime.now();
        _completionController.add(task.messageId);
        
        if (kDebugMode) {
          debugPrint('[DecryptQueueManager] Completed ${task.messageId}');
        }
        
        // Process next
        _processQueue();
      }).catchError((e) {
        _activeTasks.remove(task.messageId);
        if (kDebugMode) {
          debugPrint('[DecryptQueueManager] Failed ${task.messageId}: $e');
        }
        _processQueue();
      });
    }
  }
  
  /// Clear completed tracking (call periodically or on logout)
  void clearCompletedTracking() {
    final now = DateTime.now();
    _recentlyCompleted.removeWhere((_, time) {
      return now.difference(time) > _dedupeWindow;
    });
  }
}

class _DecryptTask {
  final String messageId;
  final Future<String> Function() decryptFn;
  final Duration timeout;
  
  final _completer = Completer<String>();
  bool _isCancelled = false;
  Timer? _timeoutTimer;
  
  _DecryptTask({
    required this.messageId,
    required this.decryptFn,
    required this.timeout,
  });
  
  bool get isCancelled => _isCancelled;
  Future<String> get future => _completer.future;
  
  Future<String> execute() async {
    if (_isCancelled) {
      throw Exception('Task cancelled');
    }
    
    _timeoutTimer = Timer(timeout, () {
      if (!_completer.isCompleted) {
        _completer.completeError(TimeoutException('Decrypt timeout for $messageId'));
      }
    });
    
    try {
      final result = await decryptFn();
      _timeoutTimer?.cancel();
      if (!_completer.isCompleted) {
        _completer.complete(result);
      }
      return result;
    } catch (e) {
      _timeoutTimer?.cancel();
      if (!_completer.isCompleted) {
        _completer.completeError(e);
      }
      rethrow;
    }
  }
  
  void cancel() {
    _isCancelled = true;
    _timeoutTimer?.cancel();
    if (!_completer.isCompleted) {
      _completer.completeError(Exception('Cancelled'));
    }
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => message;
}
