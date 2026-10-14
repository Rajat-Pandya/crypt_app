import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// Custom BlocObserver for debugging and analytics.
/// 
/// Logs all BLoC events, state changes, and errors.
/// Can be extended to send analytics to Firebase Analytics or other services.
/// 
/// Usage:
/// ```dart
/// void main() {
///   Bloc.observer = CryptBlocObserver();
///   runApp(MyApp());
/// }
/// ```
class CryptBlocObserver extends BlocObserver {
  final bool enableLogs;
  final bool enableAnalytics;

  CryptBlocObserver({
    this.enableLogs = true,
    this.enableAnalytics = false,
  });

  @override
  void onCreate(BlocBase bloc) {
    super.onCreate(bloc);
    if (enableLogs) {
      _log('🆕 BLoC Created: ${bloc.runtimeType}');
    }
  }

  @override
  void onEvent(Bloc bloc, Object? event) {
    super.onEvent(bloc, event);
    if (enableLogs) {
      _log('📤 Event: ${bloc.runtimeType} | ${event.runtimeType}');
      if (event != null) {
        _log('   Details: $event');
      }
    }
    
    if (enableAnalytics) {
      _trackEvent(bloc.runtimeType.toString(), event.runtimeType.toString());
    }
  }

  @override
  void onChange(BlocBase bloc, Change change) {
    super.onChange(bloc, change);
    if (enableLogs) {
      _log('🔄 State Change: ${bloc.runtimeType}');
      _log('   From: ${_truncate(change.currentState.toString())}');
      _log('   To: ${_truncate(change.nextState.toString())}');
    }
  }

  @override
  void onTransition(Bloc bloc, Transition transition) {
    super.onTransition(bloc, transition);
    if (enableLogs) {
      _log('➡️  Transition: ${bloc.runtimeType}');
      _log('   Event: ${transition.event.runtimeType}');
      _log('   Current: ${_truncate(transition.currentState.toString())}');
      _log('   Next: ${_truncate(transition.nextState.toString())}');
    }
  }

  @override
  void onError(BlocBase bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    if (enableLogs) {
      _log('❌ Error in ${bloc.runtimeType}: $error');
      _log('   StackTrace: $stackTrace');
    }
    
    if (enableAnalytics) {
      _trackError(bloc.runtimeType.toString(), error.toString());
    }
  }

  @override
  void onClose(BlocBase bloc) {
    super.onClose(bloc);
    if (enableLogs) {
      _log('🗑️  BLoC Closed: ${bloc.runtimeType}');
    }
  }

  void _log(String message) {
    // ignore: avoid_print
    print('[BLoC] $message');
  }

  String _truncate(String str, {int maxLength = 100}) {
    if (str.length <= maxLength) return str;
    return '${str.substring(0, maxLength)}...';
  }

  void _trackEvent(String blocName, String eventName) {
    try {
      FirebaseAnalytics.instance.logEvent(
        name: 'bloc_event',
        parameters: {
          'bloc': blocName,
          'event': eventName,
        },
      );
    } catch (e) {
      // Analytics failures should never crash the app
      // Silently ignore errors
      _log('Analytics error (ignored): $e');
    }
  }

  void _trackError(String blocName, String error) {
    try {
      FirebaseCrashlytics.instance.recordError(
        error,
        null,
        reason: 'BLoC Error in $blocName',
      );
    } catch (e) {
      // Crashlytics failures should never crash the app
      // Silently ignore errors
      _log('Crashlytics error (ignored): $e');
    }
  }
}

/// Extension to make debugging easier
extension BlocDebugExtension on Bloc {
  /// Log current state
  void logState() {
    // ignore: avoid_print
    print('[BLoC Debug] $runtimeType state: $state');
  }

  /// Log with custom message
  void log(String message) {
    // ignore: avoid_print
    print('[BLoC Debug] $runtimeType: $message');
  }
}
