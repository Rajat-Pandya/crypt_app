import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Monitors user inactivity and signs out after [_sessionTimeout].
///
/// ── Design principles ─────────────────────────────────────────────────────
///
/// 1. No BuildContext is stored beyond the call frame.
///    Timers must never close over a context — widgets are routinely
///    disposed long before a 30-minute timer fires.
///
/// 2. Sign-out is performed directly via FirebaseAuth.
///    The auth state stream in main.dart (AuthWrapper) reacts to the
///    sign-out and navigates to LoginScreen automatically.
///    No navigation call is needed here.
///
/// 3. A global key is used to show the snackbar safely.
///    This decouples the timeout handler from any specific widget's
///    context — it works regardless of which screen is active.
///
/// 4. stopMonitoring() must be called when the user manually logs out
///    to prevent the timer firing on an already-signed-out session.
/// ──────────────────────────────────────────────────────────────────────────
class SessionManager {
  static Timer? _inactivityTimer;
  static DateTime _lastActivity = DateTime.now();
  static const _sessionTimeout = Duration(minutes: 30);

  // ── Global scaffold key ───────────────────────────────────────────────
  // Provided by main.dart so the timeout handler can show a snackbar
  // without needing a BuildContext stored in a timer closure.
  //
  // Usage in main.dart:
  //   MaterialApp(
  //     scaffoldMessengerKey: SessionManager.scaffoldKey,
  //     ...
  //   )
  static final scaffoldKey = GlobalKey<ScaffoldMessengerState>();

  // ────────────────────────────────────────────────────────────────────────

  // ── Internal debug helper ──────────────────────────────────────────────
  static void _dbg(String message) {
    assert(() {
      debugPrint('[SessionManager] $message');
      return true;
    }());
  }

  // ────────────────────────────────────────────────────────────────────────

  // ── Start Session Monitoring ───────────────────────────────────────────

  /// Call once when the authenticated session begins.
  /// Does NOT require a BuildContext — timer uses scaffoldKey instead.
  static void startMonitoring() {
    _lastActivity = DateTime.now();
    _resetTimer();
    _dbg('monitoring started');
  }

  // ── Record User Activity ───────────────────────────────────────────────

  /// Call on any meaningful user interaction to reset the inactivity timer.
  /// Does NOT require a BuildContext.
  static void recordActivity() {
    _lastActivity = DateTime.now();
    _resetTimer();
  }

  // ── Stop Monitoring ────────────────────────────────────────────────────

  /// Call when the user manually logs out.
  /// Prevents the timer firing on an already-signed-out session.
  static void stopMonitoring() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _dbg('monitoring stopped');
  }

  // ── Session validity check ─────────────────────────────────────────────

  /// Returns true if the session is still within the timeout window.
  static bool isSessionValid() {
    final elapsed = DateTime.now().difference(_lastActivity);
    return elapsed < _sessionTimeout;
  }

  // ── Private: Reset Timer ───────────────────────────────────────────────

  /// Cancels any existing timer and starts a fresh one.
  ///
  /// ── Fix: no BuildContext in closure ────────────────────────────────────
  /// Previously: BuildContext was passed into this method and captured
  ///             by the Timer closure — stale after 30 minutes.
  /// Now:        Timer closure uses only static state and scaffoldKey.
  ///             No widget reference is held beyond the call frame.
  /// ─────────────────────────────────────────────────────────────────────
  static void _resetTimer() {
    _inactivityTimer?.cancel();

    _inactivityTimer = Timer(_sessionTimeout, _handleSessionTimeout);
    // ✅ No context passed — _handleSessionTimeout uses scaffoldKey
    // ✅ No closure over any widget state
  }

  // ── Private: Handle Timeout ────────────────────────────────────────────

  static Future<void> _handleSessionTimeout() async {
    // ── Fix: verify inactivity before signing out ──────────────────────
    // The timer fires at exactly _sessionTimeout after it was last reset.
    // recordActivity() resets the timer, so by the time we get here
    // the elapsed time should always be >= _sessionTimeout.
    //
    // We re-check anyway as a safety guard against clock adjustments
    // or any future code that might start the timer differently.
    final elapsed = DateTime.now().difference(_lastActivity);
    if (elapsed < _sessionTimeout) {
      // Activity occurred — timer was not reset fast enough
      // Reset it now and wait again
      _dbg('timeout fired early — rescheduling');
      _resetTimer();
      return;
    }

    _dbg('session timeout — signing out');

    // ── Sign out first — AuthWrapper reacts and shows LoginScreen ─────
    // No navigation call needed here.
    // The auth state stream in main.dart handles the redirect.
    await FirebaseAuth.instance.signOut();

    // ── Show snackbar via global key — no stale context risk ──────────
    // scaffoldKey.currentState is null if no Scaffold is mounted.
    // The null-aware call handles that safely.
    scaffoldKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Session expired. Please log in again.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );

    stopMonitoring();
    // ✅ Clean up after timeout so no zombie timer remains
  }
}
