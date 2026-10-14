import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class TelemetryService {
  static final TelemetryService _instance = TelemetryService._internal();
  factory TelemetryService() => _instance;
  TelemetryService._internal();

  bool _isInitialized = false;
  final bool _isDebugMode = kDebugMode;

  static const String _telemetryCollection = 'app_telemetry';

  final _metrics = <String, dynamic>{};
  final _latencyTracker = <String, List<int>>{};
  final _performanceMarks = <String, int>{};
  
  // Firebase Performance traces
  final _activeTraces = <String, Trace>{};
  final _httpMetrics = <String, HttpMetric>{};

  DateTime? _appStartTime;
  DateTime? _lastNetworkEvent;
  DateTime? _lastReconnectEvent;

  bool get isInitialized => _isInitialized;

  // ─────────────────────────────────────────────────────────────────────────────
  // INITIALIZATION & CRASHLYTICS
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    _appStartTime = DateTime.now();

    await _initializeCrashlytics();
    _recordStartupEvent('app_initialized');

    developer.log('[Telemetry] Initialized - Debug: $_isDebugMode');
  }

  Future<void> _initializeCrashlytics() async {
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!_isDebugMode);

      if (_isDebugMode) {
        developer.log('[Telemetry] Crashlytics disabled in debug mode');
        return;
      }

      FlutterError.onError = (error) {
        _recordCrash('FlutterError', error.exceptionAsString(), error.stack);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        _recordCrash('PlatformError', error.toString(), stack);
        return true;
      };

      developer.log('[Telemetry] Crashlytics configured for production');
    } catch (e) {
      developer.log('[Telemetry] Crashlytics init failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // CRASH REPORTING (Privacy-Safe)
  // ─────────────────────────────────────────────────────────────────────────────

  void _recordCrash(String type, String message, StackTrace? stack) {
    if (_isDebugMode) return;

    try {
      final sanitizedMessage = _sanitizeForTelemetry(message);
      FirebaseCrashlytics.instance.recordError(
        Exception(sanitizedMessage),
        stack,
        reason: type,
      );
      developer.log('[Telemetry] Crash recorded: $type');
    } catch (e) {
      developer.log('[Telemetry] Failed to record crash: $e');
    }
  }

  void recordHandledException(String context, Object error) {
    if (_isDebugMode) return;

    try {
      final sanitizedContext = _sanitizeForTelemetry(context);
      final sanitizedError = _sanitizeForTelemetry(error.toString());

      FirebaseCrashlytics.instance.recordError(
        Exception(sanitizedError),
        null,
        reason: sanitizedContext,
      );
    } catch (e) {
      developer.log('[Telemetry] Failed to record exception: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // STARTUP METRICS
  // ─────────────────────────────────────────────────────────────────────────────

  void _recordStartupEvent(String event) {
    final elapsed = _appStartTime != null
        ? DateTime.now().difference(_appStartTime!).inMilliseconds
        : 0;

    _metrics['last_startup_event'] = event;
    _metrics['startup_elapsed_ms'] = elapsed;

    _sendMetric('startup', {
      'event': event,
      'elapsed_ms': elapsed,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void recordInitializationPhase(String phase, int durationMs) {
    _sendMetric('init_phase', {
      'phase': phase,
      'duration_ms': durationMs,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // RECONNECT TELEMETRY
  // ─────────────────────────────────────────────────────────────────────────────

  void recordReconnectEvent({
    required String fromState,
    required String toState,
    required int durationMs,
  }) {
    _lastReconnectEvent = DateTime.now();

    final metric = {
      'from_state': fromState,
      'to_state': toState,
      'duration_ms': durationMs,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _metrics['last_reconnect'] = metric;
    _sendMetric('reconnect', metric);

    developer.log('[Telemetry] Reconnect: $fromState → $toState (${durationMs}ms)');
  }

  void recordNetworkStateChange(String state) {
    _lastNetworkEvent = DateTime.now();

    _sendMetric('network_state', {
      'state': state,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // FIRESTORE LISTENER METRICS
  // ─────────────────────────────────────────────────────────────────────────────

  void recordListenerCount(int activeListeners, String context) {
    _sendMetric('firestore_listeners', {
      'count': activeListeners,
      'context': context,
      'timestamp': DateTime.now().toIso8601String(),
    });

    if (activeListeners > 20) {
      developer.log('[Telemetry] High listener count: $activeListeners in $context');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // LATENCY METRICS
  // ─────────────────────────────────────────────────────────────────────────────

  void startLatencyTrace(String operationId) {
    _performanceMarks[operationId] = DateTime.now().millisecondsSinceEpoch;
    
    // Also start Firebase Performance trace
    if (!_isDebugMode) {
      startPerformanceTrace('latency_$operationId');
    }
  }

  void endLatencyTrace(String operationId, {String? category}) {
    final startTime = _performanceMarks.remove(operationId);
    if (startTime == null) return;

    final latency = DateTime.now().millisecondsSinceEpoch - startTime;

    _latencyTracker.putIfAbsent(category ?? 'general', () => []);
    _latencyTracker[category ?? 'general']!.add(latency);

    _sendMetric('latency', {
      'operation': operationId,
      'latency_ms': latency,
      'category': category ?? 'general',
      'timestamp': DateTime.now().toIso8601String(),
    });

    // Stop Firebase Performance trace
    if (!_isDebugMode) {
      stopPerformanceTrace('latency_$operationId', attributes: {
        'latency_ms': latency.toString(),
        'category': category ?? 'general',
      });
    }

    if (latency > 1000) {
      developer.log('[Telemetry] High latency: $operationId took ${latency}ms');
    }
  }

  void recordOperationLatency(String operation, int latencyMs, {String? context}) {
    _sendMetric('operation_latency', {
      'operation': operation,
      'latency_ms': latencyMs,
      'context': context,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // FIREBASE PERFORMANCE MONITORING
  // ─────────────────────────────────────────────────────────────────────────────

  /// Start a custom Firebase Performance trace
  Future<Trace?> startPerformanceTrace(String traceName) async {
    if (_isDebugMode) {
      developer.log('[Performance] Starting trace: $traceName');
      return null;
    }

    try {
      final trace = FirebasePerformance.instance.newTrace(traceName);
      await trace.start();
      _activeTraces[traceName] = trace;
      return trace;
    } catch (e) {
      developer.log('[Performance] Failed to start trace: $e');
      return null;
    }
  }

  /// Stop a custom Firebase Performance trace
  Future<void> stopPerformanceTrace(String traceName, {Map<String, String>? attributes}) async {
    final trace = _activeTraces.remove(traceName);
    if (trace == null) {
      developer.log('[Performance] Trace not found: $traceName');
      return;
    }

    try {
      if (attributes != null) {
        attributes.forEach((key, value) {
          trace.putAttribute(key, value);
        });
      }
      await trace.stop();
      developer.log('[Performance] Stopped trace: $traceName');
    } catch (e) {
      developer.log('[Performance] Failed to stop trace: $e');
    }
  }

  /// Start an HTTP metric for network request tracking
  Future<HttpMetric?> startHttpMetric(String url, HttpMethod httpMethod) async {
    if (_isDebugMode) {
      developer.log('[Performance] Starting HTTP metric: ${httpMethod.name} $url');
      return null;
    }

    try {
      final metric = FirebasePerformance.instance.newHttpMetric(url, httpMethod);
      await metric.start();
      final key = '${httpMethod.name}:$url';
      _httpMetrics[key] = metric;
      return metric;
    } catch (e) {
      developer.log('[Performance] Failed to start HTTP metric: $e');
      return null;
    }
  }

  /// Stop an HTTP metric with response data
  Future<void> stopHttpMetric(
    String url,
    HttpMethod httpMethod, {
    int? httpResponseCode,
    int? requestPayloadSize,
    int? responsePayloadSize,
    Map<String, String>? attributes,
  }) async {
    final key = '${httpMethod.name}:$url';
    final metric = _httpMetrics.remove(key);
    if (metric == null) {
      developer.log('[Performance] HTTP metric not found: $key');
      return;
    }

    try {
      if (httpResponseCode != null) {
        metric.httpResponseCode = httpResponseCode;
      }
      if (requestPayloadSize != null) {
        metric.requestPayloadSize = requestPayloadSize;
      }
      if (responsePayloadSize != null) {
        metric.responsePayloadSize = responsePayloadSize;
      }
      if (attributes != null) {
        attributes.forEach((key, value) {
          metric.putAttribute(key, value);
        });
      }
      await metric.stop();
      developer.log('[Performance] Stopped HTTP metric: $key');
    } catch (e) {
      developer.log('[Performance] Failed to stop HTTP metric: $e');
    }
  }

  /// Set a performance attribute on an active trace
  void setPerformanceAttribute(String traceName, String key, String value) {
    final trace = _activeTraces[traceName];
    if (trace != null) {
      trace.putAttribute(key, value);
    }
  }

  /// Record a performance metric (increment counter)
  void incrementPerformanceMetric(String metricName, {int value = 1}) {
    if (_isDebugMode) {
      developer.log('[Performance] Incrementing metric: $metricName by $value');
      return;
    }

    try {
      FirebasePerformance.instance.setPerformanceCollectionEnabled(true);
      // Note: Firebase Performance doesn't have direct counters, use custom traces instead
      developer.log('[Performance] Metric $metricName = $value');
    } catch (e) {
      developer.log('[Performance] Failed to record metric: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // QUEUE RECOVERY METRICS
  // ─────────────────────────────────────────────────────────────────────────────

  void recordQueueRecovery({
    required int messagesQueued,
    required int messagesRecovered,
    required int durationMs,
    required bool success,
  }) {
    final metric = {
      'queued': messagesQueued,
      'recovered': messagesRecovered,
      'duration_ms': durationMs,
      'success': success,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _metrics['last_queue_recovery'] = metric;
    _sendMetric('queue_recovery', metric);

    developer.log('[Telemetry] Queue recovery: $messagesRecovered/$messagesQueued in ${durationMs}ms');
  }

  void recordQueueError(String errorType, String details) {
    _sendMetric('queue_error', {
      'error_type': errorType,
      'details': _sanitizeForTelemetry(details),
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PERFORMANCE TRACING
  // ─────────────────────────────────────────────────────────────────────────────

  void recordFrameRenderDuration(int durationMs) {
    if (durationMs > 16) {
      _sendMetric('frame_render', {
        'duration_ms': durationMs,
        'timestamp': DateTime.now().toIso8601String(),
      });
      
      // Track slow frames via custom trace in Firebase Performance
      if (!_isDebugMode && durationMs > 100) {
        startPerformanceTrace('slow_frame').then((trace) {
          if (trace != null) {
            trace.putAttribute('duration_ms', durationMs.toString());
            trace.stop();
          }
        });
      }
    }
  }

  void recordWidgetRebuild(String widgetName, int rebuildCount) {
    _sendMetric('widget_rebuild', {
      'widget': widgetName,
      'count': rebuildCount,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void recordMemoryUsage(int usedBytes, String context) {
    _sendMetric('memory', {
      'used_bytes': usedBytes,
      'context': context,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // CHAT SERVICE METRICS
  // ─────────────────────────────────────────────────────────────────────────────

  void recordMessageSend({
    required String chatRoomId,
    required bool success,
    int? latencyMs,
  }) {
    _sendMetric('message_send', {
      'chat_room_id': _hashIdentifier(chatRoomId),
      'success': success,
      'latency_ms': latencyMs,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void recordMessageDecrypt({
    required String messageId,
    required bool success,
    int? latencyMs,
  }) {
    _sendMetric('message_decrypt', {
      'message_id': _hashIdentifier(messageId),
      'success': success,
      'latency_ms': latencyMs,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // AUTH & SESSION METRICS
  // ─────────────────────────────────────────────────────────────────────────────

  void recordAuthEvent(String event, {String? userId}) {
    _sendMetric('auth', {
      'event': event,
      'user_id': userId != null ? _hashIdentifier(userId) : null,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void recordSessionEvent(String event, {int? durationMs}) {
    _sendMetric('session', {
      'event': event,
      'duration_ms': durationMs,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // ENCRYPTION & SECURITY (No Sensitive Data)
  // ─────────────────────────────────────────────────────────────────────────────

  void recordEncryptionEvent(String event, {bool success = true}) {
    _sendMetric('encryption', {
      'event': event,
      'success': success,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void recordSecurityEvent(String event, {int? trustScore}) {
    _sendMetric('security', {
      'event': event,
      'trust_score': trustScore,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PRIVATE HELPERS
  // ─────────────────────────────────────────────────────────────────────────────

  String _hashIdentifier(String input) {
    return input.hashCode.abs().toString();
  }

  String _sanitizeForTelemetry(String input) {
    if (input.isEmpty) return '[empty]';

    final sensitivePatterns = [
      RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'),
      RegExp(r'\b\d{3}[-.]?\d{3}[-.]?\d{4}\b'),
      RegExp(r'eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*'),
      RegExp(r'-----BEGIN [A-Z]+ PRIVATE KEY-----'),
      RegExp(r'password[=:]\s*\S+', caseSensitive: false),
    ];

    var result = input;
    for (final pattern in sensitivePatterns) {
      result = result.replaceAll(pattern, '[REDACTED]');
    }

    if (result.length > 200) {
      result = '${result.substring(0, 197)}...';
    }

    return result;
  }

  void _sendMetric(String type, Map<String, dynamic> data) {
    if (_isDebugMode) {
      developer.log('[Telemetry] $type: $data');
      return;
    }

    try {
      FirebaseFirestore.instance.collection(_telemetryCollection).add({
        ...data,
        'type': type,
        'app_version': _metrics['app_version'] ?? 'unknown',
        'platform': defaultTargetPlatform.name,
      });
    } catch (e) {
      developer.log('[Telemetry] Failed to send metric: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // AGGREGATE STATS
  // ─────────────────────────────────────────────────────────────────────────────

  Map<String, dynamic> getAggregateStats() {
    final latencyAverages = <String, double>{};

    for (final entry in _latencyTracker.entries) {
      final values = entry.value;
      if (values.isNotEmpty) {
        latencyAverages[entry.key] = values.reduce((a, b) => a + b) / values.length;
      }
    }

    return {
      'latency_averages_ms': latencyAverages,
      'total_metrics_sent': _metrics.length,
      'active_traces': _performanceMarks.length,
      'uptime_ms': _appStartTime != null
          ? DateTime.now().difference(_appStartTime!).inMilliseconds
          : 0,
    };
  }

  void clearSession() {
    _latencyTracker.clear();
    _performanceMarks.clear();
    _metrics.clear();
  }
}
