// test/helpers/service_test_helper.dart
// Common utilities for testing services

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';

// Mock secure storage
class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

// Mock for testing asynchronous operations
class AsyncTestHelper {
  /// Wait for async operations to complete
  static Future<void> pump() async {
    await Future.delayed(Duration.zero);
  }

  /// Wait for specified duration
  static Future<void> delay(int milliseconds) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }

  /// Create a delayed completer for testing timeouts
  static Completer<T> delayedCompleter<T>({
    required T value,
    required int delayMs,
  }) {
    final completer = Completer<T>();
    Future.delayed(Duration(milliseconds: delayMs), () {
      completer.complete(value);
    });
    return completer;
  }
}

// Test data generators
class TestDataGenerators {
  static String generateUserId() => 'user_${DateTime.now().millisecondsSinceEpoch}';
  
  static String generateRoomId(String user1, String user2) {
    final ids = [user1, user2]..sort();
    return '${ids[0]}_${ids[1]}';
  }
  
  static String generateMessageId() => 'msg_${DateTime.now().millisecondsSinceEpoch}';
  
  static Map<String, dynamic> createTestMessage({
    String? messageId,
    String? senderId,
    String? text,
    DateTime? timestamp,
    bool? isEncrypted,
  }) {
    return {
      'messageId': messageId ?? generateMessageId(),
      'senderId': senderId ?? 'test_sender',
      'text': text ?? 'Test message',
      'timestamp': timestamp ?? DateTime.now(),
      'isEncrypted': isEncrypted ?? true,
    };
  }
  
  static Map<String, dynamic> createTestUser({
    String? uid,
    String? email,
    String? displayName,
  }) {
    return {
      'uid': uid ?? generateUserId(),
      'email': email ?? 'test@example.com',
      'displayName': displayName ?? 'Test User',
      'createdAt': DateTime.now().toIso8601String(),
    };
  }
}

// Assertion helpers
class TestAssertions {
  /// Assert that a future completes successfully
  static Future<void> completesSuccessfully(Future future) async {
    await future; // If it completes without error, test passes
  }

  /// Assert that a future throws an exception
  static Future<void> throwsException(Future future, {Type? exceptionType}) async {
    try {
      await future;
      throw TestFailure('Expected exception but completed successfully');
    } catch (e) {
      if (exceptionType != null && e.runtimeType != exceptionType) {
        throw TestFailure('Expected ${exceptionType.toString()} but got ${e.runtimeType}');
      }
      // Exception thrown as expected
    }
  }

  /// Assert that a list is not empty
  static void isNotEmpty(List? list) {
    if (list == null || list.isEmpty) {
      throw TestFailure('Expected non-empty list but got ${list?.length ?? 0} items');
    }
  }

  /// Assert that a map contains expected keys
  static void containsKeys(Map? map, List<String> keys) {
    if (map == null) {
      throw TestFailure('Expected non-null map');
    }
    for (final key in keys) {
      if (!map.containsKey(key)) {
        throw TestFailure('Expected map to contain key "$key"');
      }
    }
  }
}

class TestFailure implements Exception {
  final String message;
  TestFailure(this.message);
  
  @override
  String toString() => 'TestFailure: $message';
}
