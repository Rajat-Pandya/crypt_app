import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Key mismatch detection manager
///
/// Provides stable session identity and safe key lifecycle management
/// without breaking backward compatibility.
/// 
/// Responsibilities:
/// - Session identity management
/// - Key validation and mismatch detection
/// - Key versioning for backward compatibility

class KeyMismatchManager {
  static const _storage = FlutterSecureStorage();

  static const _sessionIdKey = 'encryption_session_id';
  static const _sessionCreatedKey = 'encryption_session_created';
  static const _lastKeyVersionKey = 'last_known_key_version';

  static String? _currentSessionId;
  static DateTime? _sessionCreated;
  static bool _initialized = false;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[KeyMismatchManager] $message');
      return true;
    }());
  }

  /// Initialize session - must be called on app start
  static Future<void> initialize() async {
    if (_initialized) return;

    _currentSessionId = await _storage.read(key: _sessionIdKey);
    final createdStr = await _storage.read(key: _sessionCreatedKey);

    if (_currentSessionId == null || createdStr == null) {
      await _createNewSession();
    } else {
      _sessionCreated = DateTime.tryParse(createdStr);
      if (_sessionCreated == null) {
        await _createNewSession();
      }
    }

    _initialized = true;
    _dbg('session initialized: $_currentSessionId, created: $_sessionCreated');
  }

  static Future<void> _createNewSession() async {
    _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _sessionCreated = DateTime.now();

    await _storage.write(key: _sessionIdKey, value: _currentSessionId);
    await _storage.write(
      key: _sessionCreatedKey,
      value: _sessionCreated!.toIso8601String(),
    );

    _dbg('new session created: $_currentSessionId');
  }

  /// Get current session ID - stable across app restarts within same session
  static String? get sessionId => _currentSessionId;

  /// Get session creation time
  static DateTime? get sessionCreated => _sessionCreated;

  /// Check if this is a new session (app restarted)
  static bool get isNewSession {
    if (_sessionCreated == null) return true;
    final now = DateTime.now();
    return now.difference(_sessionCreated!).inHours < 1;
  }

  /// Save the last known key version for comparison on next load
  static Future<void> saveKeyVersion(String version) async {
    await _storage.write(key: _lastKeyVersionKey, value: version);
    _dbg('saved key version: $version');
  }

  /// Get last known key version
  static Future<String?> getLastKeyVersion() async {
    return await _storage.read(key: _lastKeyVersionKey);
  }

  /// Check if key version changed since last session
  static Future<bool> hasKeyVersionChanged(String currentVersion) async {
    final lastVersion = await getLastKeyVersion();
    if (lastVersion == null) return false;
    return lastVersion != currentVersion;
  }

  /// Clear session data - called on logout
  static Future<void> clearSession() async {
    await _storage.delete(key: _sessionIdKey);
    await _storage.delete(key: _sessionCreatedKey);
    await _storage.delete(key: _lastKeyVersionKey);

    _currentSessionId = null;
    _sessionCreated = null;
    _initialized = false;

    _dbg('session cleared');
  }

  /// Check if keys are ready for this session
  static Future<bool> hasValidKeys() async {
    final privateKey = await _storage.read(key: 'private_key');
    return privateKey != null;
  }
}

/// Key mismatch detector - helps identify when key issues need attention
class KeyMismatchDetector {
  static int _mismatchCount = 0;
  static DateTime? _lastMismatchTime;

  static void recordMismatch() {
    _mismatchCount++;
    _lastMismatchTime = DateTime.now();
    assert(() {
      debugPrint('[KeyMismatch] count=$_mismatchCount, last=$_lastMismatchTime');
      return true;
    }());
  }

  static void clearMismatches() {
    _mismatchCount = 0;
    _lastMismatchTime = null;
  }

  static bool hasRecentMismatch() {
    if (_lastMismatchTime == null) return false;
    final diff = DateTime.now().difference(_lastMismatchTime!);
    return diff.inMinutes < 5;
  }

  static int get mismatchCount => _mismatchCount;

  static bool shouldRecommendReauth() {
    return _mismatchCount >= 5 && hasRecentMismatch();
  }
}
