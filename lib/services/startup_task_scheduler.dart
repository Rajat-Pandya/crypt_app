import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Priority levels for startup tasks
enum StartupTaskPriority {
  critical,   // Must run immediately - blocks first frame
  high,       // Run after first frame renders
  medium,     // Run 500ms after first frame
  low,        // Run 2s after first frame
  idle,       // Run when app is idle
}

/// Startup task definition
class StartupTask {
  final String name;
  final StartupTaskPriority priority;
  final Future<void> Function() task;
  final bool runOnce;
  final Duration? delay;
  
  bool _hasRun = false;
  
  StartupTask({
    required this.name,
    required this.priority,
    required this.task,
    this.runOnce = true,
    this.delay,
  });
  
  bool get canRun => !runOnce || !_hasRun;
  void markCompleted() => _hasRun = true;
}

/// Centralized startup task scheduler to prevent frame drops.
/// 
/// Ensures heavy startup work is properly prioritized and deferred:
/// - Critical: Runs immediately (Firebase init, etc.)
/// - High: Runs after first frame (user presence, basic setup)
/// - Medium: Runs 500ms after first frame (device registration)
/// - Low: Runs 2s after first frame (security checks, HMAC init)
/// - Idle: Runs when app is idle (cleanup, maintenance)
class StartupTaskScheduler {
  static final StartupTaskScheduler _instance = StartupTaskScheduler._internal();
  factory StartupTaskScheduler() => _instance;
  StartupTaskScheduler._internal();
  
  static final Map<String, StartupTask> _tasks = {};
  static final Queue<StartupTask> _pendingTasks = Queue<StartupTask>();
  static final bool _isScheduling = false;
  static bool _firstFrameRendered = false;
  static DateTime? _firstFrameTime;
  
  // Logging prefixes for filtering
  static const String _startupPrefix = '[STARTUP]';
  static const String _perfPrefix = '[PERF]';
  static const String _appCheckPrefix = '[APP_CHECK]';
  
  static void _log(String prefix, String message) {
    assert(() {
      debugPrint('$prefix $message');
      return true;
    }());
  }
  
  /// Register a task for execution
  /// 
  /// [name] - Unique task identifier
  /// [priority] - When to run the task
  /// [task] - The async function to execute
  /// [runOnce] - If true, task only runs once per app lifecycle
  /// [delay] - Additional delay after priority timing
  static void register({
    required String name,
    required StartupTaskPriority priority,
    required Future<void> Function() task,
    bool runOnce = true,
    Duration? delay,
  }) {
    if (_tasks.containsKey(name)) {
      _log(_startupPrefix, 'Task $name already registered, skipping');
      return;
    }
    
    final startupTask = StartupTask(
      name: name,
      priority: priority,
      task: task,
      runOnce: runOnce,
      delay: delay,
    );
    
    _tasks[name] = startupTask;
    _log(_startupPrefix, 'Registered task: $name (priority: ${priority.name})');
    
    // Schedule immediate execution if appropriate
    if (priority == StartupTaskPriority.critical) {
      _executeTask(startupTask);
    }
  }
  
  /// Call this after first frame renders to start executing deferred tasks
  static void onFirstFrameRendered() {
    if (_firstFrameRendered) return;
    
    _firstFrameRendered = true;
    _firstFrameTime = DateTime.now();
    _log(_perfPrefix, 'First frame rendered at ${_firstFrameTime!.millisecondsSinceEpoch}');
    
    // Schedule tasks by priority
    _scheduleTasksByPriority(StartupTaskPriority.high, Duration.zero);
    _scheduleTasksByPriority(StartupTaskPriority.medium, const Duration(milliseconds: 500));
    _scheduleTasksByPriority(StartupTaskPriority.low, const Duration(seconds: 2));
    _scheduleTasksByPriority(StartupTaskPriority.idle, const Duration(seconds: 5));
  }
  
  /// Schedule all tasks of a specific priority with optional additional delay
  static void _scheduleTasksByPriority(StartupTaskPriority priority, Duration baseDelay) {
    final tasks = _tasks.values.where((t) => 
      t.priority == priority && t.canRun
    ).toList();
    
    if (tasks.isEmpty) return;
    
    _log(_startupPrefix, 'Scheduling ${tasks.length} ${priority.name} priority tasks');
    
    // Calculate total delay (base + task-specific)
    var index = 0;
    for (final task in tasks) {
      final taskDelay = baseDelay + (task.delay ?? Duration.zero) + 
                        Duration(milliseconds: index * 50); // Stagger by 50ms
      
      Future.delayed(taskDelay, () {
        _executeTask(task);
      });
      index++;
    }
  }
  
  /// Execute a single task with error handling
  static Future<void> _executeTask(StartupTask task) async {
    if (!task.canRun) {
      _log(_startupPrefix, 'Task ${task.name} already run, skipping');
      return;
    }
    
    final startTime = DateTime.now();
    _log(_startupPrefix, 'Executing task: ${task.name}');
    
    try {
      await task.task();
      task.markCompleted();
      
      final duration = DateTime.now().difference(startTime);
      _log(_perfPrefix, 'Task ${task.name} completed in ${duration.inMilliseconds}ms');
      
    } catch (e, st) {
      _log(_startupPrefix, 'Task ${task.name} failed: ${e.runtimeType}');
      if (kDebugMode) {
        debugPrint('$e');
        debugPrintStack(stackTrace: st);
      }
    }
  }
  
  /// Execute a task in an isolate for CPU-intensive work
  /// 
  /// Note: Only use for pure computation - can't access Flutter bindings
  static Future<T> runInIsolate<T>(Future<T> Function() computation) async {
    // For now, run in microtask to avoid blocking UI
    // For true isolation, use Isolate.run() but with proper error handling
    return await Future.microtask(computation);
  }
  
  /// Get scheduler statistics for debugging
  static Map<String, dynamic> getStats() {
    return {
      'totalTasks': _tasks.length,
      'completedTasks': _tasks.values.where((t) => !t.canRun).length,
      'pendingTasks': _tasks.values.where((t) => t.canRun).length,
      'firstFrameRendered': _firstFrameRendered,
      'timeSinceFirstFrame': _firstFrameTime != null
          ? DateTime.now().difference(_firstFrameTime!).inMilliseconds
          : null,
    };
  }
  
  /// Reset all tasks (for testing)
  static void reset() {
    _tasks.clear();
    _pendingTasks.clear();
    _firstFrameRendered = false;
    _firstFrameTime = null;
    _log(_startupPrefix, 'Scheduler reset');
  }
  
  // ============================================================================
  // Background Task Management (from utils/startup_scheduler)
  // ============================================================================
  
  static bool _backgroundPaused = false;
  static bool _isNavigating = false;
  static final List<Function()> _deferredBackgroundTasks = [];
  static Timer? _deferredBackgroundTimer;
  
  /// Pause all background tasks (e.g., during navigation)
  static void pauseBackgroundTasks() {
    _isNavigating = true;
    _backgroundPaused = true;
    _log(_startupPrefix, 'Background tasks PAUSED');
  }
  
  /// Resume background tasks
  static void resumeBackgroundTasks() {
    _isNavigating = false;
    _backgroundPaused = false;
    _log(_startupPrefix, 'Background tasks RESUMED');
    _processDeferredBackgroundTasks();
  }
  
  /// Run a task when system is idle
  static void runWhenIdle(Function() task) {
    if (!_backgroundPaused && !_isNavigating) {
      task();
    } else {
      _deferredBackgroundTasks.add(task);
      _log(_startupPrefix, 'Task deferred (paused=$_backgroundPaused, navigating=$_isNavigating)');
      
      _deferredBackgroundTimer?.cancel();
      _deferredBackgroundTimer = Timer(const Duration(milliseconds: 100), () {
        _processDeferredBackgroundTasks();
      });
    }
  }
  
  static void _processDeferredBackgroundTasks() {
    if (_deferredBackgroundTasks.isEmpty) return;
    if (_backgroundPaused || _isNavigating) {
      _log(_startupPrefix, 'Deferred tasks waiting (paused=$_backgroundPaused, navigating=$_isNavigating)');
      return;
    }
    
    _log(_startupPrefix, 'Processing ${_deferredBackgroundTasks.length} deferred background tasks');
    
    final batchSize = 5;
    final tasksToRun = _deferredBackgroundTasks.take(batchSize).toList();
    _deferredBackgroundTasks.removeRange(0, tasksToRun.length);
    
    for (final task in tasksToRun) {
      try {
        task();
      } catch (e) {
        _log(_startupPrefix, 'Deferred task error: $e');
      }
    }
    
    if (_deferredBackgroundTasks.isNotEmpty) {
      _deferredBackgroundTimer?.cancel();
      _deferredBackgroundTimer = Timer(const Duration(milliseconds: 50), () {
        _processDeferredBackgroundTasks();
      });
    }
  }
  
  /// Cancel all pending background tasks
  static void cancelAllBackgroundTasks() {
    _deferredBackgroundTimer?.cancel();
    _deferredBackgroundTasks.clear();
    _log(_startupPrefix, 'All background tasks cancelled');
  }
  
  /// Mark critical initialization phase as complete
  /// Call this after first frame renders to start processing deferred tasks
  static void markCriticalPhaseComplete() {
    _log(_startupPrefix, 'Critical phase complete');
    onFirstFrameRendered();
    _processDeferredBackgroundTasks();
  }
}

/// Extension for easy task registration
extension StartupTaskSchedulerExtension on StartupTaskScheduler {
  /// Register critical task (runs immediately)
  static void critical(String name, Future<void> Function() task) {
    StartupTaskScheduler.register(
      name: name,
      priority: StartupTaskPriority.critical,
      task: task,
    );
  }
  
  /// Register high priority task (runs after first frame)
  static void high(String name, Future<void> Function() task, {Duration? delay}) {
    StartupTaskScheduler.register(
      name: name,
      priority: StartupTaskPriority.high,
      task: task,
      delay: delay,
    );
  }
  
  /// Register medium priority task (runs 500ms after first frame)
  static void medium(String name, Future<void> Function() task, {Duration? delay}) {
    StartupTaskScheduler.register(
      name: name,
      priority: StartupTaskPriority.medium,
      task: task,
      delay: delay,
    );
  }
  
  /// Register low priority task (runs 2s after first frame)
  static void low(String name, Future<void> Function() task, {Duration? delay}) {
    StartupTaskScheduler.register(
      name: name,
      priority: StartupTaskPriority.low,
      task: task,
      delay: delay,
    );
  }
  
  /// Register idle task (runs when app is idle)
  static void idle(String name, Future<void> Function() task) {
    StartupTaskScheduler.register(
      name: name,
      priority: StartupTaskPriority.idle,
      task: task,
    );
  }
}
