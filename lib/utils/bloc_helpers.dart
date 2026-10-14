import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/chat_bloc.dart';
import '../blocs/connectivity_bloc.dart';
import '../blocs/encryption_bloc.dart';
import '../blocs/game_bloc.dart';

/// Widget that provides all BLoCs to the widget tree.
/// 
/// Usage:
/// ```dart
/// AppBlocProviders(
///   child: ChatScreen(receiverId: 'user123'),
/// )
/// ```
class AppBlocProviders extends StatelessWidget {
  final Widget child;

  const AppBlocProviders({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => ConnectivityBloc()
            ..add(const ConnectivityInitialized()),
        ),
        BlocProvider(
          create: (context) => EncryptionBloc(),
        ),
      ],
      child: child,
    );
  }
}

/// Extension methods for easier BLoC access
extension BlocContextExtensions on BuildContext {
  ChatBloc get chatBloc => read<ChatBloc>();
  ConnectivityBloc get connectivityBloc => read<ConnectivityBloc>();
  EncryptionBloc get encryptionBloc => read<EncryptionBloc>();
  GameBloc get gameBloc => read<GameBloc>();
}

/// Helper widget that listens to connectivity changes
/// and rebuilds when connectivity state changes.
class ConnectivityListener extends StatelessWidget {
  final Widget child;
  final Function(bool isOnline)? onConnectivityChanged;

  const ConnectivityListener({
    super.key,
    required this.child,
    this.onConnectivityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return BlocListener<ConnectivityBloc, ConnectivityState>(
      listenWhen: (previous, current) =>
        previous.isOnline != current.isOnline,
      listener: (context, state) {
        onConnectivityChanged?.call(state.isOnline);
      },
      child: child,
    );
  }
}

/// Widget that builds based on ChatBloc state changes.
/// 
/// Usage:
/// ```dart
/// ChatBlocBuilder(
///   builder: (context, state) {
///     return Text('${state.messages.length} messages');
///   },
/// )
/// ```
class ChatBlocBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, ChatState state) builder;

  const ChatBlocBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatBloc, ChatState>(
      builder: builder,
    );
  }
}

/// Widget that shows a snackbar when an error occurs in ChatBloc.
class ChatErrorListener extends StatelessWidget {
  final Widget child;

  const ChatErrorListener({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return BlocListener<ChatBloc, ChatState>(
      listenWhen: (previous, current) =>
        previous.error != current.error && current.error != null,
      listener: (context, state) {
        if (state.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.error!),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: child,
    );
  }
}

/// Helper class to migrate common UI patterns to BLoC events.
class BlocEventHelpers {
  /// Toggle selection for a message.
  static void toggleSelection(BuildContext context, String messageId, bool isSelected) {
    final bloc = context.read<ChatBloc>();
    if (isSelected) {
      bloc.add(MessageDeselected(messageId));
    } else {
      bloc.add(MessageSelected(messageId));
    }
  }

  /// Clear selection.
  static void clearSelection(BuildContext context) {
    context.read<ChatBloc>().add(const ClearSelection());
  }

  /// Start selecting mode.
  static void startSelecting(BuildContext context) {
    context.read<ChatBloc>().add(const SelectionModeToggled(true));
  }

  /// Stop selecting mode.
  static void stopSelecting(BuildContext context) {
    context.read<ChatBloc>().add(const SelectionModeToggled(false));
  }

  /// Search for messages.
  static void search(BuildContext context, String query) {
    context.read<ChatBloc>().add(SearchQueryChanged(query));
  }

  /// Clear search.
  static void clearSearch(BuildContext context) {
    context.read<ChatBloc>().add(const SearchQueryChanged(''));
  }

  /// Set reply to message.
  static void setReply(BuildContext context, String messageId, String preview) {
    context.read<ChatBloc>().add(ReplyToMessageSet(
      messageId: messageId,
      preview: preview,
    ));
  }

  /// Clear reply.
  static void clearReply(BuildContext context) {
    context.read<ChatBloc>().add(const ReplyToMessageSet());
  }

  /// Start editing message.
  static void startEditing(BuildContext context, String messageId, String text) {
    context.read<ChatBloc>().add(EditMessageModeSet(
      messageId: messageId,
      currentText: text,
    ));
  }

  /// Stop editing message.
  static void stopEditing(BuildContext context) {
    context.read<ChatBloc>().add(const EditMessageModeSet());
  }

  /// Send message.
  static void sendMessage(BuildContext context, String text, {String? replyToMessageId}) {
    context.read<ChatBloc>().add(SendMessageRequested(
      text,
      replyToMessageId: replyToMessageId,
    ));
  }

  /// Start typing.
  static void startTyping(BuildContext context) {
    context.read<ChatBloc>().add(const TypingStarted());
  }

  /// Stop typing.
  static void stopTyping(BuildContext context) {
    context.read<ChatBloc>().add(const TypingStopped());
  }

  /// Toggle mute.
  static void toggleMute(BuildContext context, bool isMuted) {
    context.read<ChatBloc>().add(MuteToggled(isMuted));
  }

  // ==========================================================================
  // Encryption Helpers
  // ==========================================================================

  /// Initialize encryption for chat.
  static void initEncryption(BuildContext context, String currentUserId, String receiverId) {
    context.read<EncryptionBloc>().add(EncryptionInitialized(
      currentUserId: currentUserId,
      receiverId: receiverId,
    ));
  }

  /// Load encryption keys.
  static void loadEncryptionKeys(BuildContext context, {bool forceRefresh = false}) {
    context.read<EncryptionBloc>().add(LoadEncryptionKeys(forceRefresh: forceRefresh));
  }

  /// Load receiver's public key.
  static void loadReceiverPublicKey(BuildContext context, String receiverId) {
    context.read<EncryptionBloc>().add(LoadReceiverPublicKey(receiverId));
  }

  /// Decrypt a message.
  static void decryptMessage(
    BuildContext context, {
    required String messageId,
    required String encryptedText,
    required bool isOwnMessage,
    required String senderId,
    String keyVersion = '',
  }) {
    context.read<EncryptionBloc>().add(DecryptMessage(
      messageId: messageId,
      encryptedText: encryptedText,
      isOwnMessage: isOwnMessage,
      senderId: senderId,
      keyVersion: keyVersion,
    ));
  }

  /// Batch decrypt messages.
  static void batchDecryptMessages(BuildContext context, List<Map<String, dynamic>> messages) {
    context.read<EncryptionBloc>().add(BatchDecryptMessages(messages));
  }

  /// Clear decryption cache.
  static void clearDecryptCache(BuildContext context) {
    context.read<EncryptionBloc>().add(const ClearDecryptCache());
  }

  /// Invalidate specific message from cache.
  static void invalidateMessageCache(BuildContext context, String messageId) {
    context.read<EncryptionBloc>().add(InvalidateMessageCache(messageId));
  }

  /// Rotate encryption keys.
  static void rotateKeys(BuildContext context) {
    context.read<EncryptionBloc>().add(const RotateKeys());
  }

  // ==========================================================================
  // Game Helpers
  // ==========================================================================

  /// Initialize game.
  static void initGame(BuildContext context, String roomId, String currentUserId) {
    context.read<GameBloc>().add(GameInitialized(
      roomId: roomId,
      currentUserId: currentUserId,
    ));
  }

  /// Load game state.
  static void loadGameState(BuildContext context) {
    context.read<GameBloc>().add(const LoadGameState());
  }

  /// Start a new game.
  static void startGame(BuildContext context, String gameType, {Map<String, dynamic>? settings}) {
    context.read<GameBloc>().add(StartGame(gameType, settings: settings));
  }

  /// Make a move.
  static void makeMove(BuildContext context, int position, String playerId) {
    context.read<GameBloc>().add(MakeMove(
      position: position,
      playerId: playerId,
    ));
  }

  /// End game.
  static void endGame(BuildContext context, {String? winnerId, String? reason}) {
    context.read<GameBloc>().add(EndGame(
      winnerId: winnerId,
      reason: reason,
    ));
  }

  /// Reset game.
  static void resetGame(BuildContext context) {
    context.read<GameBloc>().add(const ResetGame());
  }

  /// Join game.
  static void joinGame(BuildContext context, String playerId, String playerName) {
    context.read<GameBloc>().add(PlayerJoined(playerId, playerName));
  }

  /// Leave game.
  static void leaveGame(BuildContext context, String playerId) {
    context.read<GameBloc>().add(PlayerLeft(playerId));
  }

  /// Toggle game mode.
  static void toggleGameMode(BuildContext context, bool isActive) {
    context.read<GameBloc>().add(ToggleGameMode(isActive));
  }
}

/// Mixin that provides event dispatching helpers for StatefulWidgets.
/// 
/// Usage:
/// ```dart
/// class _MyScreenState extends State<MyScreen> with EventDispatchMixin {
///   void _onSomeAction() {
///     dispatchSelection(messageId);
///   }
/// }
/// ```
mixin EventDispatchMixin<T extends StatefulWidget> on State<T> {
  void dispatchSelection(String messageId) {
    context.read<ChatBloc>().add(MessageSelected(messageId));
  }

  void dispatchDeselection(String messageId) {
    context.read<ChatBloc>().add(MessageDeselected(messageId));
  }

  void dispatchClearSelection() {
    context.read<ChatBloc>().add(const ClearSelection());
  }

  void dispatchSearch(String query) {
    context.read<ChatBloc>().add(SearchQueryChanged(query));
  }

  void dispatchSendMessage(String text, {String? replyToMessageId}) {
    context.read<ChatBloc>().add(SendMessageRequested(
      text,
      replyToMessageId: replyToMessageId,
    ));
  }

  void dispatchDecryptMessage(String messageId, String encryptedText, bool isMe, String senderId) {
    context.read<EncryptionBloc>().add(DecryptMessage(
      messageId: messageId,
      encryptedText: encryptedText,
      isOwnMessage: isMe,
      senderId: senderId,
    ));
  }

  void dispatchLoadEncryptionKeys() {
    context.read<EncryptionBloc>().add(const LoadEncryptionKeys());
  }

  void dispatchStartGame(String gameType) {
    context.read<GameBloc>().add(StartGame(gameType));
  }

  void dispatchMakeMove(int position, String playerId) {
    context.read<GameBloc>().add(MakeMove(
      position: position,
      playerId: playerId,
    ));
  }

  void dispatchEndGame({String? winnerId}) {
    context.read<GameBloc>().add(EndGame(winnerId: winnerId));
  }
}
