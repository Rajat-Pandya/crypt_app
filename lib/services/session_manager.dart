import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'session_lifecycle_manager.dart';

/// DEPRECATED: Use SessionLifecycleManager instead.
/// 
/// This class is kept for backward compatibility and delegates all calls
/// to SessionLifecycleManager.
/// 
/// Migration guide:
/// - SessionManager.startMonitoring() → SessionLifecycleManager.initializeSession(user)
/// - SessionManager.recordActivity() → SessionLifecycleManager.recordActivity()
/// - SessionManager.stopMonitoring() → SessionLifecycleManager.terminateSession()
@Deprecated('Use SessionLifecycleManager instead. This will be removed in a future version.')
class SessionManager {
  /// Re-export scaffoldKey from SessionLifecycleManager
  static GlobalKey<ScaffoldMessengerState> get scaffoldKey => 
      SessionLifecycleManager.scaffoldKey;

  /// DEPRECATED: Use SessionLifecycleManager.initializeSession(user) instead
  @Deprecated('Use SessionLifecycleManager.initializeSession(user)')
  static Future<void> startMonitoring() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await SessionLifecycleManager.initializeSession(user);
    }
  }

  /// DEPRECATED: Use SessionLifecycleManager.resumeInactivityMonitoring()
  @Deprecated('Use SessionLifecycleManager.resumeInactivityMonitoring()')
  static Future<void> resumeMonitoring() async {
    await SessionLifecycleManager.resumeInactivityMonitoring();
  }

  /// DEPRECATED: Use SessionLifecycleManager.recordActivity()
  @Deprecated('Use SessionLifecycleManager.recordActivity()')
  static Future<void> recordActivity() async {
    await SessionLifecycleManager.recordActivity();
  }

  /// DEPRECATED: Use SessionLifecycleManager.terminateSession()
  @Deprecated('Use SessionLifecycleManager.terminateSession()')
  static Future<void> stopMonitoring() async {
    await SessionLifecycleManager.terminateSession();
  }

  /// DEPRECATED: Use SessionLifecycleManager.pauseMonitoring()
  @Deprecated('Use SessionLifecycleManager.pauseMonitoring()')
  static Future<void> pauseMonitoring() async {
    await SessionLifecycleManager.pauseMonitoring();
  }

  /// DEPRECATED: Use SessionLifecycleManager.isMonitoring
  @Deprecated('Use SessionLifecycleManager.isMonitoring')
  static bool get isMonitoring => SessionLifecycleManager.isMonitoring;

  /// DEPRECATED: Use SessionLifecycleManager.currentState
  @Deprecated('Use SessionLifecycleManager.currentState')
  static bool isSessionValid() {
    return SessionLifecycleManager.currentState == SessionState.active ||
           SessionLifecycleManager.currentState == SessionState.recovered;
  }

  /// DEPRECATED: Use SessionLifecycleManager.terminateSession()
  @Deprecated('Use SessionLifecycleManager.terminateSession()')
  static Future<void> clearStoredActivity() async {
    await SessionLifecycleManager.terminateSession();
  }
}
