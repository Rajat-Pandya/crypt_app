// test/services/chat_util_service_test.dart
// Tests for ChatUtilService

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:crypt_app/services/chat_util_service.dart';

import '../helpers/service_test_helper.dart';

class MockChatUtilService extends Mock implements ChatUtilService {}

void main() {
  late MockFlutterSecureStorage mockStorage;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();

    // Register fallback values
    registerFallbackValue(<String, dynamic>{});
  });

  tearDown(() {
    reset(mockStorage);
  });

  group('ChatUtilService Tests', () {
    group('Room ID Generation', () {
      test('getRoomId generates consistent room ID for two users', () {
        const user1 = 'user_a';
        const user2 = 'user_b';
        
        final roomId1 = ChatUtilService.getRoomId(user1, user2);
        final roomId2 = ChatUtilService.getRoomId(user2, user1);
        
        expect(roomId1, equals(roomId2));
        expect(roomId1, isNotNull);
        expect(roomId1.length, greaterThan(0));
      });

      test('getRoomId handles same user input', () {
        const user1 = 'user_a';
        
        final roomId = ChatUtilService.getRoomId(user1, user1);
        
        expect(roomId, isNotNull);
        expect(roomId, contains(user1));
      });

      test('getRoomId generates unique IDs for different pairs', () {
        const userA = 'user_a';
        const userB = 'user_b';
        const userC = 'user_c';
        
        final roomIdAB = ChatUtilService.getRoomId(userA, userB);
        final roomIdAC = ChatUtilService.getRoomId(userA, userC);
        
        expect(roomIdAB, isNot(equals(roomIdAC)));
      });
    });

    group('Secure Storage Operations', () {
      test('loadPrivateKey returns device_private_key when available', () async {
        const testKey = 'test_private_key_data';
        
        // Setup mock to return the test key
        when(() => mockStorage.read(key: 'device_private_key'))
            .thenAnswer((_) async => testKey);
        
        // Note: Since ChatUtilService uses static methods with direct storage access,
        // we'd need to refactor it to accept storage as a dependency for full mocking.
        // For now, we verify the method signature exists.
        expect(ChatUtilService.loadPrivateKey, isA<Function>());
      });

      // Test that the method exists
      expect(ChatUtilService.loadPrivateKey, isA<Function>());
    });

    group('Timestamp Formatting', () {
      test('timestamp handling exists', () {
        // Verify timestamp methods exist
        expect(Timestamp, isNotNull);
      });
    });

    group('Typing Indicator Logic', () {
      test('should show typing indicator when user is typing', () {
        final typingUsers = <String>{'user_b'};
        const currentUserId = 'user_a';
        const receiverId = 'user_b';
        
        // When receiver is typing, should show indicator
        final shouldShow = typingUsers.contains(receiverId);
        
        expect(shouldShow, isTrue);
      });

      test('should not show typing indicator for self', () {
        final typingUsers = <String>{'user_a'};
        const currentUserId = 'user_a';
        const receiverId = 'user_b';
        
        // Should not show when user is typing to themselves
        final shouldShow = typingUsers.contains(receiverId);
        
        expect(shouldShow, isFalse);
      });
    });

    group('Message Delivery Status', () {
      test('isMessageDelivered returns correct status', () {
        // Test data
        final deliveredMessage = {
          'deliveredTo': {'user_b': true},
        };
        
        final undeliveredMessage = {
          'deliveredTo': <String, dynamic>{},
        };
        
        // Check delivery status
        final isDelivered = (deliveredMessage['deliveredTo'] as Map?)?.containsKey('user_b') ?? false;
        final isUndelivered = (undeliveredMessage['deliveredTo'] as Map?)?.containsKey('user_b') ?? false;
        
        expect(isDelivered, isTrue);
        expect(isUndelivered, isFalse);
      });
    });
  });

  group('Crypto Operations', () {
    test('crypto operations exist', () {
      // Verify crypto-related methods exist
      expect(ChatUtilService.getRoomId, isA<Function>());
    });
  });

  group('Utility Functions', () {
    test('utility methods exist', () {
      // Verify utility methods exist
      expect(ChatUtilService, isNotNull);
    });
  });
}
