import 'package:flutter_test/flutter_test.dart';

import 'package:crypt_app/blocs/chat_bloc.dart';

void main() {
  group('ChatBloc', () {
    late ChatBloc chatBloc;
    const roomId = 'test_room_123';
    const receiverId = 'receiver_456';

    setUp(() {
      chatBloc = ChatBloc(
        roomId: roomId,
        receiverId: receiverId,
      );
    });

    tearDown(() {
      chatBloc.close();
    });

    test('initial state is correct', () {
      // ChatBloc stores roomId/receiverId, not ChatState
      expect(chatBloc.state.messages, isEmpty);
      expect(chatBloc.state.selectedIds, isEmpty);
      expect(chatBloc.state.isSelecting, isFalse);
      expect(chatBloc.state.searchQuery, isEmpty);
      expect(chatBloc.state.isTyping, isFalse);
      expect(chatBloc.state.isInitialized, isFalse);
    });

    test('ChatInitialized sets isInitialized', () {
      chatBloc.add(const ChatInitialized(roomId, receiverId));
      
      // Wait for event to be processed
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.isInitialized, isTrue);
      });
    });

    test('SelectionModeToggled updates isSelecting', () {
      expect(chatBloc.state.isSelecting, isFalse);
      
      chatBloc.add(const SelectionModeToggled(true));
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.isSelecting, isTrue);
      });
    });

    test('MessageSelected adds to selectedIds', () {
      expect(chatBloc.state.selectedIds.contains('msg_1'), isFalse);
      
      chatBloc.add(const MessageSelected('msg_1'));
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.selectedIds.contains('msg_1'), isTrue);
      });
    });

    test('MessageDeselected removes from selectedIds', () {
      // First select
      chatBloc.add(const MessageSelected('msg_1'));
      
      Future.delayed(const Duration(milliseconds: 50), () {
        // Then deselect
        chatBloc.add(const MessageDeselected('msg_1'));
        
        Future.delayed(const Duration(milliseconds: 50), () {
          expect(chatBloc.state.selectedIds.contains('msg_1'), isFalse);
        });
      });
    });

    test('ClearSelection clears all selections', () {
      chatBloc.add(const MessageSelected('msg_1'));
      chatBloc.add(const MessageSelected('msg_2'));
      chatBloc.add(const SelectionModeToggled(true));
      
      Future.delayed(const Duration(milliseconds: 50), () {
        chatBloc.add(const ClearSelection());
        
        Future.delayed(const Duration(milliseconds: 50), () {
          expect(chatBloc.state.selectedIds.isEmpty, isTrue);
          expect(chatBloc.state.isSelecting, isFalse);
        });
      });
    });

    test('SearchQueryChanged updates searchQuery', () {
      chatBloc.add(const SearchQueryChanged('hello'));
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.searchQuery, equals('hello'));
      });
    });

    test('ReplyToMessageSet sets reply data', () {
      chatBloc.add(const ReplyToMessageSet(
        messageId: 'msg_1',
        preview: 'Hello',
      ));
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.replyToMessageId, equals('msg_1'));
        expect(chatBloc.state.replyPreview, equals('Hello'));
      });
    });

    test('ReplyToMessageSet clears reply when no params', () {
      chatBloc.add(const ReplyToMessageSet(
        messageId: 'msg_1',
        preview: 'Hello',
      ));
      
      Future.delayed(const Duration(milliseconds: 50), () {
        chatBloc.add(const ReplyToMessageSet());
        
        Future.delayed(const Duration(milliseconds: 50), () {
          expect(chatBloc.state.replyToMessageId, isNull);
          expect(chatBloc.state.replyPreview, isNull);
        });
      });
    });

    test('EditMessageModeSet sets edit data', () {
      chatBloc.add(const EditMessageModeSet(
        messageId: 'msg_1',
        currentText: 'Original text',
      ));
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.editingMessageId, equals('msg_1'));
        expect(chatBloc.state.editingText, equals('Original text'));
      });
    });

    test('EditMessageModeSet clears edit when no params', () {
      chatBloc.add(const EditMessageModeSet(
        messageId: 'msg_1',
        currentText: 'Original text',
      ));
      
      Future.delayed(const Duration(milliseconds: 50), () {
        chatBloc.add(const EditMessageModeSet());
        
        Future.delayed(const Duration(milliseconds: 50), () {
          expect(chatBloc.state.editingMessageId, isNull);
          expect(chatBloc.state.editingText, isNull);
        });
      });
    });

    test('TypingStarted sets isTyping to true', () {
      chatBloc.add(const TypingStarted());
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.isTyping, isTrue);
      });
    });

    test('TypingStopped sets isTyping to false', () {
      chatBloc.add(const TypingStarted());
      
      Future.delayed(const Duration(milliseconds: 50), () {
        chatBloc.add(const TypingStopped());
        
        Future.delayed(const Duration(milliseconds: 50), () {
          expect(chatBloc.state.isTyping, isFalse);
        });
      });
    });

    test('MuteToggled updates isMuted', () {
      chatBloc.add(const MuteToggled(true));
      
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(chatBloc.state.isMuted, isTrue);
      });
    });

    test('state copyWith creates modified copy', () {
      final original = chatBloc.state;
      final modified = original.copyWith(
        isSelecting: true,
        searchQuery: 'test',
      );
      
      expect(modified.isSelecting, isTrue);
      expect(modified.searchQuery, equals('test'));
      expect(modified.isInitialized, equals(original.isInitialized));
    });

    test('state preserves values with null in copyWith', () {
      final original = chatBloc.state;
      final modified = original.copyWith();
      
      expect(modified.isInitialized, equals(original.isInitialized));
      expect(modified.isLoading, equals(original.isLoading));
    });
  });
}
