import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import 'session_lifecycle_manager.dart' as slm;

/// DEPRECATED: Use SessionState from SessionLifecycleManager.
@Deprecated('Use SessionState from SessionLifecycleManager.')
enum SessionRecoveryState {
  idle,
  checking,
  healthy,
  needsRecovery,
  recovering,
  recovered,
  failed,
}

/// DEPRECATED: Use SessionMetadata from SessionLifecycleManager.
@Deprecated('Use SessionMetadata from SessionLifecycleManager.')
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

  factory SessionMetadata._fromNew(slm.SessionMetadata m) {
    return SessionMetadata(
      sessionId: m.sessionId,
      deviceId: m.deviceId,
      createdAt: m.createdAt,
      lastValidatedAt: m.lastValidatedAt,
      sequenceNumber: m.sequenceNumber,
      syncedFromDevice: m.syncedFromDevice,
      isRecovered: m.isRecovered,
    );
  }
}

/// DEPRECATED: Use RecoveryResult from SessionLifecycleManager.
@Deprecated('Use RecoveryResult from SessionLifecycleManager.')
class RecoveryResult {
  final bool success;
  final SessionRecoveryState state;
  final String? message;
  final DateTime timestamp;

  const RecoveryResult({
    required this.success,
    required this.state,
    this.message,
    required this.timestamp,
  });

  factory RecoveryResult._fromNew(slm.RecoveryResult r) {
    return RecoveryResult(
      success: r.success,
      state: _mapStateFromNew(r.state),
      message: r.message,
      timestamp: r.timestamp,
    );
  }
}

SessionRecoveryState _mapStateFromNew(slm.SessionState state) {
  switch (state) {
    case slm.SessionState.idle: return SessionRecoveryState.idle;
    case slm.SessionState.active: return SessionRecoveryState.healthy;
    case slm.SessionState.needsRecovery: return SessionRecoveryState.needsRecovery;
    case slm.SessionState.recovering: return SessionRecoveryState.recovering;
    case slm.SessionState.recovered: return SessionRecoveryState.recovered;
    case slm.SessionState.failed: return SessionRecoveryState.failed;
  }
}

/// DEPRECATED: Use SessionLifecycleManager instead.
@Deprecated('Use SessionLifecycleManager instead.')
class SessionRecoveryService {
  static final SessionRecoveryService _instance = SessionRecoveryService._internal();
  factory SessionRecoveryService() => _instance;
  SessionRecoveryService._internal();

  static Stream<SessionRecoveryState> get stateStream => 
      slm.SessionLifecycleManager.stateStream.map(_mapStateFromNew);

  static Stream<RecoveryResult> get recoveryStream => 
      slm.SessionLifecycleManager.recoveryStream.map(RecoveryResult._fromNew);

  static SessionRecoveryState get currentState => 
      _mapStateFromNew(slm.SessionLifecycleManager.currentState);

  static SessionMetadata? get currentSession {
    final m = slm.SessionLifecycleManager.currentSession;
    return m != null ? SessionMetadata._fromNew(m) : null;
  }

  static Future<SessionMetadata> initializeSession(User user) async {
    final m = await slm.SessionLifecycleManager.initializeSession(user);
    return SessionMetadata._fromNew(m);
  }

  static Future<RecoveryResult> checkAndRecover(User user) async {
    final r = await slm.SessionLifecycleManager.checkAndRecover(user);
    return RecoveryResult._fromNew(r);
  }

  static Future<void> syncToTrustedDevices(User user) async {
    await slm.SessionLifecycleManager.syncToTrustedDevices(user);
  }

  static Future<bool> recoverFromDevice({
    required User user,
    required String sourceDeviceId,
  }) async {
    return await slm.SessionLifecycleManager.recoverFromDevice(
      user: user,
      sourceDeviceId: sourceDeviceId,
    );
  }

  static Future<bool> validateSession(User user) async {
    return await slm.SessionLifecycleManager.validateSession(user);
  }

  static Future<void> cleanupStaleSessions(User user) async {
    await slm.SessionLifecycleManager.cleanupStaleSessions(user);
  }

  static Future<List<SessionMetadata>> getActiveSessions(User user) async {
    final list = await slm.SessionLifecycleManager.getActiveSessions(user);
    return list.map((m) => SessionMetadata._fromNew(m)).toList();
  }

  static Future<bool> terminateSession({
    required User user,
    required String deviceId,
  }) async {
    await slm.SessionLifecycleManager.terminateSession();
    return true;
  }

  static Future<void> reset() async {
    await slm.SessionLifecycleManager.terminateSession();
  }

}
