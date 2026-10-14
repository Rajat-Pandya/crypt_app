import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_service.dart';
import 'device_trust_service.dart';

/// Session lifecycle state
enum SessionState {
  /// No active session
  idle,

  /// Session initialized and healthy
  active,

  /// Session needs recovery
  needsRecovery,

  /// Recovering session from trusted device
  recovering,

  /// Session recovered successfully
  recovered,

  /// Recovery failed
  failed,
}

/// Recovery result
class RecoveryResult {
  final bool success;
  final SessionState state;
  final String? message;
  final DateTime timestamp;

  const RecoveryResult({
    required this.success,
    required this.state,
    this.message,
    required this.timestamp,
  });
}

/// Session metadata for lifecycle management
class SessionMetadata {
  final String sessionId;
  final String deviceId;
  final DateTime createdAt;
  final DateTime lastValidatedAt;
  final int sequenceNumber;
  final String? syncedFromDevice;
  final bool isRecovered;

  SessionMetadata({
    required this.sessionId,
    required this.deviceId,
    required this.createdAt,
    required this.lastValidatedAt,
    required this.sequenceNumber,
    this.syncedFromDevice,
    this.isRecovered = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'sessionId': sessionId,
      'deviceId': deviceId,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'lastValidatedAt': lastValidatedAt.millisecondsSinceEpoch,
      'sequenceNumber': sequenceNumber,
      'syncedFromDevice': syncedFromDevice,
      'isRecovered': isRecovered,
    };
  }

  static SessionMetadata fromMap(Map<String, dynamic> map) {
    return SessionMetadata(
      sessionId: map['sessionId'] as String,
      deviceId: map['deviceId'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      lastValidatedAt: DateTime.fromMillisecondsSinceEpoch(map['lastValidatedAt'] as int),
      sequenceNumber: map['sequenceNumber'] as int,
      syncedFromDevice: map['syncedFromDevice'] as String?,
      isRecovered: map['isRecovered'] as bool? ?? false,
    );
  }

  SessionMetadata copyWith({
    DateTime? lastValidatedAt,
    int? sequenceNumber,
    String? syncedFromDevice,
    bool? isRecovered,
  }) {
    return SessionMetadata(
      sessionId: sessionId,
      deviceId: deviceId,
      createdAt: createdAt,
      lastValidatedAt: lastValidatedAt ?? this.lastValidatedAt,
      sequenceNumber: sequenceNumber ?? this.sequenceNumber,
      syncedFromDevice: syncedFromDevice ?? this.syncedFromDevice,
      isRecovered: isRecovered ?? this.isRecovered,
    );
  }
}

/// Unified session lifecycle manager.
///
/// Combines inactivity timeout monitoring with session recovery and cross-device sync.
/// Previously split across SessionManager + SessionRecoveryService.
class SessionLifecycleManager {
  // ==========================================================================
  // INACTIVITY TIMEOUT (from SessionManager)
  // ==========================================================================
  
  static Timer? _inactivityTimer;
  static DateTime _lastActivity = DateTime.now();
  static const _sessionTimeout = Duration(minutes: 30);
  static const String _lastActivityKey = 'session_last_activity';
  static final scaffoldKey = GlobalKey<ScaffoldMessengerState>();
  
  // State guards
  static bool _isStarting = false;
  static bool _isRecording = false;
  static DateTime _lastRecordTime = DateTime.now();
  static const _minRecordInterval = Duration(seconds: 1);
  
  // Session timing
  static DateTime? _sessionStartTime;
  static const _minSessionDuration = Duration(seconds: 5);

  // ==========================================================================
  // RECOVERY & SYNC (from SessionRecoveryService)
  // ==========================================================================
  
  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();
  
  static SessionMetadata? _currentSession;
  static SessionState _state = SessionState.idle;
  static final _stateController = StreamController<SessionState>.broadcast();
  static final _recoveryController = StreamController<RecoveryResult>.broadcast();
  
  // Configuration
  static const Duration _sessionStaleThreshold = Duration(minutes: 30);
  static const Duration _sessionCleanupThreshold = Duration(days: 7);
  static const String _sessionKey = 'current_session';

  // ==========================================================================
  // STREAMS
  // ==========================================================================
  
  /// Stream of session state changes
  static Stream<SessionState> get stateStream => _stateController.stream;

  /// Stream of recovery results
  static Stream<RecoveryResult> get recoveryStream => _recoveryController.stream;

  /// Current session state
  static SessionState get currentState => _state;

  /// Current session metadata
  static SessionMetadata? get currentSession => _currentSession;

  /// Track if monitoring is active
  static bool get isMonitoring => _inactivityTimer != null && _inactivityTimer!.isActive;

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  /// Initialize full session lifecycle.
  /// 
  /// Combines session initialization + recovery + timeout monitoring start.
  static Future<SessionMetadata> initializeSession(User user) async {
    _dbg('initializeSession: START - uid: ${user.uid}');

    try {
      // Check for existing session
      final existingSession = await _loadSession();

      if (existingSession != null) {
        _dbg('initializeSession: found existing session ${existingSession.sessionId}');

        // Check if session is stale
        if (_isSessionStale(existingSession)) {
          _dbg('initializeSession: session is stale, attempting recovery');
          _setState(SessionState.needsRecovery);

          final recovered = await _attemptRecovery(user, existingSession);
          if (recovered) {
            await startInactivityMonitoring();
            return _currentSession!;
          }
        }

        // Session is valid
        _currentSession = existingSession.copyWith(
          lastValidatedAt: DateTime.now(),
          sequenceNumber: existingSession.sequenceNumber + 1,
        );
        await _persistSession(_currentSession!);
        await _syncSessionToFirestore(user, _currentSession!);
        await startInactivityMonitoring();

        _setState(SessionState.active);
        _dbg('initializeSession: session validated');
        return _currentSession!;
      }

      // Create new session
      final deviceId = await DeviceService.getDeviceId();
      final sessionId = _generateSessionId(user.uid, deviceId);

      await _cleanupDuplicateSessions(user, deviceId);

      _currentSession = SessionMetadata(
        sessionId: sessionId,
        deviceId: deviceId,
        createdAt: DateTime.now(),
        lastValidatedAt: DateTime.now(),
        sequenceNumber: 0,
      );

      await _persistSession(_currentSession!);
      await _syncSessionToFirestore(user, _currentSession!);
      await startInactivityMonitoring();

      _setState(SessionState.active);
      _dbg('initializeSession: new session created');
      return _currentSession!;
    } catch (e) {
      _dbg('initializeSession: ERROR - $e');
      _setState(SessionState.failed);
      rethrow;
    }
  }

  /// Check and recover session on reconnect.
  /// Called when app comes back online or after long background.
  static Future<RecoveryResult> checkAndRecover(User user) async {
    _dbg('checkAndRecover: START - uid: ${user.uid}');
    _setState(SessionState.recovering);

    try {
      // Load current session
      final session = await _loadSession();

      if (session == null) {
        _dbg('checkAndRecover: no session found, initializing new');
        await initializeSession(user);
        return RecoveryResult(
          success: true,
          state: SessionState.recovered,
          message: 'New session initialized',
          timestamp: DateTime.now(),
        );
      }

      _currentSession = session;

      // Check device trust
      if (!await DeviceTrustService.isTrusted(user)) {
        _dbg('checkAndRecover: device not trusted');
        _setState(SessionState.failed);
        return RecoveryResult(
          success: false,
          state: SessionState.failed,
          message: 'Device not trusted',
          timestamp: DateTime.now(),
        );
      }

      // Check if stale
      if (_isSessionStale(session)) {
        _dbg('checkAndRecover: session is stale, attempting recovery');
        final recovered = await _attemptRecovery(user, session);
        
        if (recovered) {
          return RecoveryResult(
            success: true,
            state: SessionState.recovered,
            message: 'Session recovered from trusted device',
            timestamp: DateTime.now(),
          );
        } else {
          await _clearSession();
          await initializeSession(user);
          return RecoveryResult(
            success: true,
            state: SessionState.recovered,
            message: 'New session created after failed recovery',
            timestamp: DateTime.now(),
          );
        }
      }

      // Session healthy
      _currentSession = session.copyWith(
        lastValidatedAt: DateTime.now(),
        sequenceNumber: session.sequenceNumber + 1,
      );
      await _persistSession(_currentSession!);
      await _syncSessionToFirestore(user, _currentSession!);
      await resumeInactivityMonitoring();

      _setState(SessionState.active);
      return RecoveryResult(
        success: true,
        state: SessionState.active,
        message: 'Session is healthy',
        timestamp: DateTime.now(),
      );
    } catch (e) {
      _dbg('checkAndRecover: ERROR - $e');
      _setState(SessionState.failed);
      return RecoveryResult(
        success: false,
        state: SessionState.failed,
        message: 'Recovery failed: $e',
        timestamp: DateTime.now(),
      );
    }
  }

  /// Start inactivity monitoring.
  static Future<void> startInactivityMonitoring() async {
    if (_isStarting) {
      _dbg('startInactivityMonitoring: already starting');
      return;
    }

    if (_sessionStartTime != null) {
      final elapsed = DateTime.now().difference(_sessionStartTime!);
      if (elapsed < _minSessionDuration) {
        _dbg('startInactivityMonitoring: session started too recently');
        return;
      }
    }

    if (isMonitoring) {
      _dbg('startInactivityMonitoring: already monitoring');
      await recordActivity();
      return;
    }

    _isStarting = true;

    try {
      await _loadLastActivity();
      _lastActivity = DateTime.now();
      _sessionStartTime = DateTime.now();
      await _persistLastActivity();
      _resetInactivityTimer();
      _dbg('Inactivity monitoring started');
    } finally {
      _isStarting = false;
    }
  }

  /// Resume monitoring after background/app restart.
  static Future<void> resumeInactivityMonitoring() async {
    _dbg('resumeInactivityMonitoring: checking session validity');

    await _loadLastActivity();

    if (!_isSessionValid()) {
      _dbg('resumeInactivityMonitoring: session expired');
      await FirebaseAuth.instance.signOut();
      scaffoldKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Session expired. Please log in again.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ),
      );
      await terminateSession();
      return;
    }

    if (!isMonitoring) {
      await startInactivityMonitoring();
    } else {
      _resetInactivityTimer();
    }
  }

  /// Record user activity to reset inactivity timer.
  static Future<void> recordActivity() async {
    final now = DateTime.now();
    
    if (now.difference(_lastRecordTime) < _minRecordInterval) {
      _resetInactivityTimer();
      return;
    }

    if (_isRecording) return;
    if (!_isSessionValid()) {
      _dbg('recordActivity: session expired');
      return;
    }

    _isRecording = true;

    try {
      _lastActivity = now;
      _lastRecordTime = now;
      await _persistLastActivity();
      _resetInactivityTimer();
    } finally {
      _isRecording = false;
    }
  }

  /// Terminate session and cleanup.
  static Future<void> terminateSession() async {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _sessionStartTime = null;
    _isStarting = false;
    _isRecording = false;
    _currentSession = null;
    _state = SessionState.idle;
    
    await _clearSession();
    await _clearStoredActivity();
    _dbg('Session terminated');
  }

  /// Pause monitoring without clearing state.
  static Future<void> pauseMonitoring() async {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    await _persistLastActivity();
    _dbg('Monitoring paused');
  }

  /// Sync session to trusted devices.
  static Future<void> syncToTrustedDevices(User user) async {
    if (_currentSession == null) return;

    try {
      await _syncSessionToFirestore(user, _currentSession!);
      _dbg('Synced to trusted devices');
    } catch (e) {
      _dbg('syncToTrustedDevices: ERROR - $e');
    }
  }

  /// Recover session from specific device.
  static Future<bool> recoverFromDevice({
    required User user,
    required String sourceDeviceId,
  }) async {
    _dbg('recoverFromDevice: from $sourceDeviceId');
    _setState(SessionState.recovering);

    try {
      final doc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .doc(sourceDeviceId)
          .get();

      if (!doc.exists) {
        _dbg('recoverFromDevice: no session found');
        _setState(SessionState.failed);
        return false;
      }

      final data = doc.data()!;
      _currentSession = SessionMetadata(
        sessionId: data['sessionId'] as String,
        deviceId: await DeviceService.getDeviceId(),
        createdAt: DateTime.now(),
        lastValidatedAt: DateTime.now(),
        sequenceNumber: (data['sequenceNumber'] as int? ?? 0) + 1,
        syncedFromDevice: sourceDeviceId,
        isRecovered: true,
      );

      await _persistSession(_currentSession!);
      await _syncSessionToFirestore(user, _currentSession!);

      _setState(SessionState.recovered);
      return true;
    } catch (e) {
      _dbg('recoverFromDevice: ERROR - $e');
      _setState(SessionState.failed);
      return false;
    }
  }

  /// Validate current session.
  static Future<bool> validateSession(User user) async {
    try {
      final session = await _loadSession();
      if (session == null) return false;
      if (_isSessionStale(session)) return false;

      final doc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .doc(session.deviceId)
          .get();

      if (!doc.exists) return false;

      final data = doc.data()!;
      final remoteSequence = data['sequenceNumber'] as int? ?? 0;

      // Replay protection
      if (remoteSequence > session.sequenceNumber) return false;

      return true;
    } catch (e) {
      _dbg('validateSession: ERROR - $e');
      return false;
    }
  }

  /// Get active sessions for user.
  static Future<List<SessionMetadata>> getActiveSessions(User user) async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .orderBy('lastValidatedAt', descending: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return SessionMetadata(
          sessionId: data['sessionId'] as String,
          deviceId: data['deviceId'] as String,
          createdAt: (data['createdAt'] as Timestamp).toDate(),
          lastValidatedAt: (data['lastValidatedAt'] as Timestamp).toDate(),
          sequenceNumber: data['sequenceNumber'] as int? ?? 0,
          syncedFromDevice: data['syncedFromDevice'] as String?,
          isRecovered: data['isRecovered'] as bool? ?? false,
        );
      }).toList();
    } catch (e) {
      _dbg('getActiveSessions: ERROR - $e');
      return [];
    }
  }

  /// Cleanup stale sessions.
  static Future<void> cleanupStaleSessions(User user) async {
    try {
      final cutoff = DateTime.now().subtract(_sessionCleanupThreshold);

      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .where('lastValidatedAt', isLessThan: Timestamp.fromDate(cutoff))
          .get();

      for (final doc in snapshot.docs) {
        await doc.reference.delete();
      }

      _dbg('cleanupStaleSessions: deleted ${snapshot.docs.length} stale sessions');
    } catch (e) {
      _dbg('cleanupStaleSessions: ERROR - $e');
    }
  }

  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================

  static void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _inactivityTimer = Timer(_sessionTimeout, _handleInactivityTimeout);
  }

  static Future<void> _handleInactivityTimeout() async {
    _inactivityTimer = null;

    final elapsed = DateTime.now().difference(_lastActivity);
    if (elapsed < _sessionTimeout) {
      _resetInactivityTimer();
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await terminateSession();
      return;
    }

    await FirebaseAuth.instance.signOut();
    scaffoldKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Session expired. Please log in again.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 5),
      ),
    );

    await terminateSession();
  }

  static bool _isSessionValid() {
    final elapsed = DateTime.now().difference(_lastActivity);
    return elapsed < _sessionTimeout;
  }

  static Future<void> _persistLastActivity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastActivityKey, _lastActivity.toIso8601String());
    } catch (e) {
      _dbg('Failed to persist activity: $e');
    }
  }

  static Future<void> _loadLastActivity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_lastActivityKey);
      if (saved != null) {
        final parsed = DateTime.tryParse(saved);
        if (parsed != null) {
          final elapsed = DateTime.now().difference(parsed);
          if (elapsed <= _sessionTimeout) {
            _lastActivity = parsed;
          } else {
            _lastActivity = DateTime.now();
          }
        }
      }
    } catch (e) {
      _dbg('Failed to load activity: $e');
    }
  }

  static Future<void> _clearStoredActivity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastActivityKey);
    } catch (e) {
      _dbg('Failed to clear activity: $e');
    }
  }

  static bool _isSessionStale(SessionMetadata session) {
    final elapsed = DateTime.now().difference(session.lastValidatedAt);
    return elapsed > _sessionStaleThreshold;
  }

  static Future<SessionMetadata?> _loadSession() async {
    try {
      final json = await _storage.read(key: _sessionKey);
      if (json == null) return null;
      return SessionMetadata.fromMap(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      _dbg('_loadSession: ERROR - $e');
      return null;
    }
  }

  static Future<void> _persistSession(SessionMetadata session) async {
    try {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toMap()),
      );
    } catch (e) {
      _dbg('_persistSession: ERROR - $e');
    }
  }

  static Future<void> _clearSession() async {
    await _storage.delete(key: _sessionKey);
  }

  static Future<void> _syncSessionToFirestore(
    User user,
    SessionMetadata session,
  ) async {
    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('device_sessions')
        .doc(session.deviceId)
        .set({
      'sessionId': session.sessionId,
      'deviceId': session.deviceId,
      'createdAt': Timestamp.fromDate(session.createdAt),
      'lastValidatedAt': Timestamp.fromDate(session.lastValidatedAt),
      'sequenceNumber': session.sequenceNumber,
      'syncedFromDevice': session.syncedFromDevice,
      'isRecovered': session.isRecovered,
    });
  }

  static Future<void> _cleanupDuplicateSessions(
    User user,
    String deviceId,
  ) async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .where('deviceId', isEqualTo: deviceId)
          .get();

      for (final doc in snapshot.docs) {
        if (doc.id != deviceId) {
          await doc.reference.delete();
        }
      }
    } catch (e) {
      _dbg('_cleanupDuplicateSessions: ERROR - $e');
    }
  }

  static Future<bool> _attemptRecovery(
    User user,
    SessionMetadata currentSession,
  ) async {
    try {
      final sessions = await getActiveSessions(user);
      final otherSessions = sessions
          .where((s) => s.deviceId != currentSession.deviceId)
          .where((s) => !_isSessionStale(s))
          .toList();

      if (otherSessions.isEmpty) return false;

      return await recoverFromDevice(
        user: user,
        sourceDeviceId: otherSessions.first.deviceId,
      );
    } catch (e) {
      _dbg('_attemptRecovery: ERROR - $e');
      return false;
    }
  }

  static String _generateSessionId(String uid, String deviceId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = timestamp % 10000;
    return '${uid.substring(0, 8)}_${deviceId.substring(0, 8)}_${timestamp}_$random';
  }

  static void _setState(SessionState state) {
    _state = state;
    _stateController.add(state);
    _dbg('State: ${state.name}');
  }

  static void _dbg(String message) {
    assert(() {
      debugPrint('[SessionLifecycle] $message');
      return true;
    }());
  }
}
