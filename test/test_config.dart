// test/test_config.dart
// Test configuration and setup

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Global test configuration
class TestConfig {
  /// Whether to run tests in verbose mode
  static bool verbose = false;
  
  /// Default timeout for async operations
  static const Duration defaultTimeout = Duration(seconds: 5);
  
  /// Whether to skip Firebase-dependent tests
  static bool skipFirebaseTests = false;
  
  /// Whether to skip integration tests
  static bool skipIntegrationTests = true;
}

/// Initialize test environment
void setupTestEnvironment() {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set up mocktail fallbacks
  _registerFallbackValues();
}

void _registerFallbackValues() {
  // Register common fallback values for mocktail
  registerFallbackValue(<String, dynamic>{});
  registerFallbackValue(<String>[]);
  registerFallbackValue(<String, String>{});
  registerFallbackValue(DateTime.now());
  registerFallbackValue(Duration.zero);
  registerFallbackValue(Exception('fallback'));
}

/// Custom test wrapper with common setup
void serviceTest(
  String description,
  Future<void> Function() body, {
  bool skip = false,
  Timeout? timeout,
  Object? tags,
}) {
  test(
    description,
    () async {
      setupTestEnvironment();
      await body();
    },
    skip: skip,
    timeout: timeout ?? Timeout(TestConfig.defaultTimeout),
    tags: tags,
  );
}

/// Group wrapper for service tests
void serviceGroup(
  String description,
  void Function() body, {
  bool skip = false,
}) {
  group(
    description,
    () {
      setUpAll(setupTestEnvironment);
      body();
    },
    skip: skip,
  );
}

/// Bloc test wrapper with Firebase mocking
void firebaseBlocTest(
  String description,
  Future<void> Function() body, {
  bool skip = false,
  Timeout? timeout,
}) {
  test(
    description,
    () async {
      if (TestConfig.skipFirebaseTests) {
        markTestSkipped('Firebase tests disabled');
        return;
      }
      setupTestEnvironment();
      await body();
    },
    skip: skip || TestConfig.skipFirebaseTests,
    timeout: timeout ?? Timeout(TestConfig.defaultTimeout),
  );
}
