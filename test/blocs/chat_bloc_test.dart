// test/blocs/chat_bloc_test.dart
// Tests for ChatBloc using flutter_test and mocktail

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:crypt_app/blocs/chat_bloc.dart';

// Simple mock classes without Firebase dependencies for unit tests
class MockUser extends Mock implements User {
  @override
  String get uid => 'test_uid_123';
  
  @override
  String? get email => 'test@example.com';
}

void main() {
  group('ChatBloc', () {
    const roomId = 'test_room_123';
    const receiverId = 'receiver_456';
    
    group('Initial State', () {
      test('should have correct initial state', () {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        expect(bloc.state.messages, isEmpty);
        expect(bloc.state.selectedIds, isEmpty);
        expect(bloc.state.isSelecting, isFalse);
        expect(bloc.state.searchQuery, isEmpty);
        expect(bloc.state.isTyping, isFalse);
        expect(bloc.state.isInitialized, isFalse);
        expect(bloc.state.isLoading, isFalse);
        expect(bloc.state.isMuted, isFalse);
        expect(bloc.state.roomExists, isFalse);
        
        bloc.close();
      });
    });

    group('ChatInitialized', () {
      test('should set isInitialized to true', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const ChatInitialized(roomId, receiverId));
        
        // Wait for event processing
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.isInitialized, isTrue);
        
        bloc.close();
      });
    });

    group('SelectionModeToggled', () {
      test('should toggle isSelecting from false to true', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        expect(bloc.state.isSelecting, isFalse);
        
        bloc.add(const SelectionModeToggled(true));
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.isSelecting, isTrue);
        
        bloc.close();
      });

      test('should toggle isSelecting from true to false', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const SelectionModeToggled(true));
        await Future.delayed(const Duration(milliseconds: 50));
        expect(bloc.state.isSelecting, isTrue);
        
        bloc.add(const SelectionModeToggled(false));
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.isSelecting, isFalse);
        
        bloc.close();
      });
    });

    group('MessageSelected', () {
      test('should add message ID to selectedIds', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const MessageSelected('msg_1'));
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.selectedIds.contains('msg_1'), isTrue);
        
        bloc.close();
      });

      test('should allow multiple selections', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const MessageSelected('msg_1'));
        bloc.add(const MessageSelected('msg_2'));
        bloc.add(const MessageSelected('msg_3'));
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.selectedIds, containsAll(['msg_1', 'msg_2', 'msg_3']));
        
        bloc.close();
      });
    });

    group('MessageDeselected', () {
      test('should remove message ID from selectedIds', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        // First select
        bloc.add(const MessageSelected('msg_1'));
        await Future.delayed(const Duration(milliseconds: 50));
        
        // Then deselect
        bloc.add(const MessageDeselected('msg_1'));
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.selectedIds.contains('msg_1'), isFalse);
        
        bloc.close();
      });
    });

    group('ClearSelection', () {
      test('should clear all selections and set isSelecting to false', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        // Select multiple messages
        bloc.add(const MessageSelected('msg_1'));
        bloc.add(const MessageSelected('msg_2'));
        bloc.add(const SelectionModeToggled(true));
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.selectedIds.isEmpty, isFalse);
        expect(bloc.state.isSelecting, isTrue);
        
        // Clear selection
        bloc.add(const ClearSelection());
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.selectedIds.isEmpty, isTrue);
        expect(bloc.state.isSelecting, isFalse);
        
        bloc.close();
      });
    });

    group('SearchQueryChanged', () {
      test('should update searchQuery', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const SearchQueryChanged('hello world'));
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.searchQuery, equals('hello world'));
        
        bloc.close();
      });

      test('should update to empty string', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const SearchQueryChanged('test'));
        await Future.delayed(const Duration(milliseconds: 50));
        
        bloc.add(const SearchQueryChanged(''));
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.searchQuery, equals(''));
        
        bloc.close();
      });
    });

    group('ReplyToMessageSet', () {
      test('should set reply data', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const ReplyToMessageSet(
          messageId: 'msg_123',
          preview: 'Hello there',
        ));
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.replyToMessageId, equals('msg_123'));
        expect(bloc.state.replyPreview, equals('Hello there'));
        
        bloc.close();
      });

      test('should clear reply data when called with no params', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        // Set reply first
        bloc.add(const ReplyToMessageSet(
          messageId: 'msg_123',
          preview: 'Hello',
        ));
        await Future.delayed(const Duration(milliseconds: 50));
        
        // Clear reply
        bloc.add(const ReplyToMessageSet());
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.replyToMessageId, isNull);
        expect(bloc.state.replyPreview, isNull);
        
        bloc.close();
      });
    });

    group('EditMessageModeSet', () {
      test('should set edit data', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const EditMessageModeSet(
          messageId: 'msg_456',
          currentText: 'Original text',
        ));
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.editingMessageId, equals('msg_456'));
        expect(bloc.state.editingText, equals('Original text'));
        
        bloc.close();
      });

      test('should clear edit data when called with no params', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        // Set edit mode first
        bloc.add(const EditMessageModeSet(
          messageId: 'msg_456',
          currentText: 'Original',
        ));
        await Future.delayed(const Duration(milliseconds: 50));
        
        // Clear edit mode
        bloc.add(const EditMessageModeSet());
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.editingMessageId, isNull);
        expect(bloc.state.editingText, isNull);
        
        bloc.close();
      });
    });

    group('TypingStarted/Stopped', () {
      test('should set isTyping to true when TypingStarted', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const TypingStarted());
        
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.isTyping, isTrue);
        
        bloc.close();
      });

      test('should set isTyping to false when TypingStopped', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const TypingStarted());
        await Future.delayed(const Duration(milliseconds: 50));
        
        bloc.add(const TypingStopped());
        await Future.delayed(const Duration(milliseconds: 50));
        
        expect(bloc.state.isTyping, isFalse);
        
        bloc.close();
      });
    });

    group('MuteToggled', () {
      test('should update isMuted', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const MuteToggled(true));
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.isMuted, isTrue);
        
        bloc.add(const MuteToggled(false));
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.isMuted, isFalse);
        
        bloc.close();
      });
    });

    group('RoomExistsChanged', () {
      test('should update roomExists', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const RoomExistsChanged(true));
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.roomExists, isTrue);
        
        bloc.close();
      });
    });

    group('EmojiPickerToggled', () {
      test('should update showEmojiPicker', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        bloc.add(const EmojiPickerToggled(true));
        await Future.delayed(const Duration(milliseconds: 100));
        
        expect(bloc.state.showEmojiPicker, isTrue);
        
        bloc.close();
      });
    });

    group('State copyWith', () {
      test('should create modified copy', () {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        final original = bloc.state;
        
        final modified = original.copyWith(
          isSelecting: true,
          searchQuery: 'test',
        );
        
        expect(modified.isSelecting, isTrue);
        expect(modified.searchQuery, equals('test'));
        expect(modified.isInitialized, equals(original.isInitialized));
        
        bloc.close();
      });

      test('should preserve values with null in copyWith', () {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        final original = bloc.state;
        
        final modified = original.copyWith();
        
        expect(modified.isInitialized, equals(original.isInitialized));
        expect(modified.isLoading, equals(original.isLoading));
        
        bloc.close();
      });
    });

    group('Edge Cases', () {
      test('should handle rapid state changes', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        // Rapid toggles
        bloc.add(const SelectionModeToggled(true));
        bloc.add(const SelectionModeToggled(false));
        bloc.add(const SelectionModeToggled(true));
        bloc.add(const SelectionModeToggled(false));
        
        await Future.delayed(const Duration(milliseconds: 200));
        
        expect(bloc.state.isSelecting, isFalse);
        
        bloc.close();
      });

      test('should maintain selection state when other state changes', () async {
        final bloc = ChatBloc(roomId: roomId, receiverId: receiverId);
        
        // Set up selection
        bloc.add(const MessageSelected('msg_1'));
        bloc.add(const MessageSelected('msg_2'));
        bloc.add(const SelectionModeToggled(true));
        await Future.delayed(const Duration(milliseconds: 100));
        
        // Change other state
        bloc.add(const SearchQueryChanged('search term'));
        await Future.delayed(const Duration(milliseconds: 100));
        
        // Selection should be preserved
        expect(bloc.state.selectedIds, containsAll(['msg_1', 'msg_2']));
        expect(bloc.state.isSelecting, isTrue);
        expect(bloc.state.searchQuery, equals('search term'));
        
        bloc.close();
      });
    });
  });
}
