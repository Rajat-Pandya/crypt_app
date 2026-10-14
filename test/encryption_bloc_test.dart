import 'package:flutter_test/flutter_test.dart';

import 'package:crypt_app/blocs/encryption_bloc.dart';

void main() {
  group('EncryptionBloc', () {
    late EncryptionBloc encryptionBloc;
    const currentUserId = 'user_123';
    const receiverId = 'receiver_456';

    setUp(() {
      encryptionBloc = EncryptionBloc();
    });

    tearDown(() {
      encryptionBloc.close();
    });

    test('initial state is correct', () {
      expect(encryptionBloc.state.isInitialized, isFalse);
      expect(encryptionBloc.state.isLoading, isFalse);
      expect(encryptionBloc.state.keysReady, isFalse);
      expect(encryptionBloc.state.receiverKeyReady, isFalse);
      expect(encryptionBloc.state.decryptCache, isEmpty);
      expect(encryptionBloc.state.activeDecryptCount, equals(0));
    });

    test('EncryptionInitialized sets isInitialized', () {
      encryptionBloc.add(const EncryptionInitialized(
        currentUserId: currentUserId,
        receiverId: receiverId,
      ));
      expect(encryptionBloc.state.isInitialized, isTrue);
    });

    test('LoadEncryptionKeys sets isLoading', () {
      encryptionBloc.add(const LoadEncryptionKeys());
      expect(encryptionBloc.state.isLoading, isTrue);
    });

    test('MessageDecrypted adds to cache', () {
      encryptionBloc.add(const MessageDecrypted(
        messageId: 'msg_1',
        decryptedText: 'Hello',
      ));
      expect(encryptionBloc.state.decryptCache['msg_1'], equals('Hello'));
    });

    test('ClearDecryptCache clears cache', () {
      encryptionBloc.add(const MessageDecrypted(
        messageId: 'msg_1',
        decryptedText: 'Hello',
      ));
      encryptionBloc.add(const ClearDecryptCache());
      expect(encryptionBloc.state.decryptCache.isEmpty, isTrue);
    });

    test('isMessageDecrypted returns true for decrypted', () {
      encryptionBloc.add(const MessageDecrypted(
        messageId: 'msg_1',
        decryptedText: 'Hello',
      ));
      expect(encryptionBloc.state.isMessageDecrypted('msg_1'), isTrue);
    });

    test('isMessageDecrypted returns false for pending', () {
      encryptionBloc.add(const EncryptionInitialized(
        currentUserId: currentUserId,
        receiverId: receiverId,
      ));
      expect(encryptionBloc.state.isMessageDecrypted('msg_1'), isFalse);
    });

    test('getDecryptedText returns text for decrypted', () {
      encryptionBloc.add(const MessageDecrypted(
        messageId: 'msg_1',
        decryptedText: 'Hello',
      ));
      expect(encryptionBloc.state.getDecryptedText('msg_1'), equals('Hello'));
    });

    test('getDecryptedText returns null for not decrypted', () {
      expect(encryptionBloc.state.getDecryptedText('msg_1'), isNull);
    });

    test('canDecryptMore returns true under limit', () {
      expect(encryptionBloc.state.canDecryptMore, isTrue);
    });

    test('allKeysReady returns true when both ready', () {
      encryptionBloc.add(const EncryptionInitialized(
        currentUserId: currentUserId,
        receiverId: receiverId,
      ));
      expect(encryptionBloc.state.allKeysReady, isFalse);
    });

    test('state copyWith creates modified copy', () {
      final original = encryptionBloc.state;
      final modified = original.copyWith(
        keysReady: true,
        activeDecryptCount: 5,
      );
      expect(modified.keysReady, isTrue);
      expect(modified.activeDecryptCount, equals(5));
    });
  });
}
