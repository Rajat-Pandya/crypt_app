import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

import '../blocs/chat_bloc.dart';
import '../blocs/connectivity_bloc.dart';

/// Widget that provides error banner and offline banner based on BLoC state.
/// 
/// Usage:
/// ```dart
/// ChatScreenBodyBuilder(
///   body: YourChatBody(),
/// )
/// ```
class ChatScreenBodyBuilder extends StatelessWidget {
  final Widget body;

  const ChatScreenBodyBuilder({
    super.key,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint('[ChatScreenBodyBuilder] build: START');
    return BlocBuilder<ChatBloc, ChatState>(
      buildWhen: (previous, current) =>
          previous.error != current.error ||
          previous.isLoadingMore != current.isLoadingMore,
      builder: (context, chatState) {
        debugPrint('[ChatScreenBodyBuilder] ChatBloc builder: error="${chatState.error}", isLoadingMore=${chatState.isLoadingMore}');
        return BlocBuilder<ConnectivityBloc, ConnectivityState>(
          buildWhen: (previous, current) =>
              previous.isOnline != current.isOnline,
          builder: (context, connectivityState) {
            debugPrint('[ChatScreenBodyBuilder] ConnectivityBloc builder: isOnline=${connectivityState.isOnline}');
            return Column(
              children: [
                // Error banner - MIGRATED from _errorMessage
                if (chatState.error?.isNotEmpty == true) ...[
                  MaterialBanner(
                    content: Text(
                      chatState.error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Colors.red.shade700,
                    leading: const Icon(
                      Icons.error_outline,
                      color: Colors.white,
                    ),
                    actions: [
                      TextButton(
                      onPressed: () {
                        debugPrint('[ChatScreenBodyBuilder] User dismissed error banner');
                        context.read<ChatBloc>().add(const ErrorOccurred(''));
                      },
                      child: const Text(
                        'DISMISS',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                ],
                // Offline banner - MIGRATED from _isOnline
                if (!connectivityState.isOnline) ...[
                  MaterialBanner(
                    content: const Text(
                      'You are offline. Messages will be sent when connected.',
                      style: TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Colors.orange.shade700,
                    leading: const Icon(
                      Icons.wifi_off,
                      color: Colors.white,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          debugPrint('[ChatScreenBodyBuilder] User requested reconnect');
                          // Retry connection
                          context.read<ConnectivityBloc>().add(const ReconnectRequested());
                        },
                        child: const Text(
                          'RETRY',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
                // Loading more indicator - MIGRATED from _isLoadingMore
                if (chatState.isLoadingMore) ...[
                  const LinearProgressIndicator(),
                ],
                // Main body
                Expanded(
                  child: Builder(
                    builder: (context) {
                      debugPrint('[ChatScreenBodyBuilder] Building main body');
                      return body;
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Widget that shows a loading indicator based on ChatBloc state.
class ChatLoadingIndicator extends StatelessWidget {
  const ChatLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('[ChatLoadingIndicator] build: START');
    return BlocBuilder<ChatBloc, ChatState>(
      buildWhen: (previous, current) =>
          previous.isLoading != current.isLoading,
      builder: (context, state) {
        debugPrint('[ChatLoadingIndicator] ChatBloc builder: isLoading=${state.isLoading}');
        if (state.isLoading) {
          debugPrint('[ChatLoadingIndicator] Showing loading indicator');
          return const LinearProgressIndicator();
        }
        return const SizedBox.shrink();
      },
    );
  }
}

/// Widget that provides emoji picker based on ChatBloc state.
class EmojiPickerWrapper extends StatelessWidget {
  final Function(String emoji) onEmojiSelected;

  const EmojiPickerWrapper({
    super.key,
    required this.onEmojiSelected,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint('[EmojiPickerWrapper] build: START');
    return BlocBuilder<ChatBloc, ChatState>(
      buildWhen: (previous, current) =>
          previous.showEmojiPicker != current.showEmojiPicker,
      builder: (context, state) {
        debugPrint('[EmojiPickerWrapper] ChatBloc builder: showEmojiPicker=${state.showEmojiPicker}');
        if (!state.showEmojiPicker) {
          return const SizedBox.shrink();
        }
        
        // Real emoji picker from emoji_picker_flutter package
        return SizedBox(
          height: 250,
          child: EmojiPicker(
            onEmojiSelected: (category, emoji) {
              debugPrint('[EmojiPickerWrapper] Emoji selected: ${emoji.emoji}');
              onEmojiSelected(emoji.emoji);
            },
            config: Config(
              height: 256,
              checkPlatformCompatibility: true,
              emojiViewConfig: EmojiViewConfig(
                columns: 7,
                emojiSizeMax: 28,
                verticalSpacing: 0,
                horizontalSpacing: 0,
                gridPadding: EdgeInsets.zero,
                buttonMode: ButtonMode.MATERIAL,
              ),
              categoryViewConfig: const CategoryViewConfig(),
              bottomActionBarConfig: const BottomActionBarConfig(),
              searchViewConfig: const SearchViewConfig(),
            ),
          ),
        );
      },
    );
  }
}
