import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../cache/models/message_cache.dart';

/// Service for handling message actions (copy, delete, forward, etc.).
class MessageActionService {
  static final MessageActionService _instance = MessageActionService._internal();
  factory MessageActionService() => _instance;
  MessageActionService._internal();

  /// Copy message text to clipboard.
  static Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Show message options bottom sheet (WhatsApp-style).
  static void showMessageOptions({
    required BuildContext context,
    required MessageCache message,
    required bool isMe,
    required String roomId,
    required String currentUserId,
    required VoidCallback onReply,
    required VoidCallback onForward,
    required VoidCallback onCopy,
    required VoidCallback onDelete,
    required VoidCallback onStar,
    required VoidCallback onReact,
    required VoidCallback onInfo,
  }) {
    HapticFeedback.mediumImpact();

    final isSingleSelection = true; // Called for single message

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _MessageOptionsSheet(
        isMe: isMe,
        isText: message.messageType == 'text' || message.messageType == null,
        isStarred: message.starred ?? false,
        onReply: () {
          Navigator.pop(context);
          onReply();
        },
        onForward: () {
          Navigator.pop(context);
          onForward();
        },
        onCopy: () {
          Navigator.pop(context);
          onCopy();
        },
        onDelete: () {
          Navigator.pop(context);
          onDelete();
        },
        onStar: () {
          Navigator.pop(context);
          onStar();
        },
        onReact: () {
          Navigator.pop(context);
          onReact();
        },
        onInfo: isSingleSelection
            ? () {
                Navigator.pop(context);
                onInfo();
              }
            : null,
      ),
    );
  }

  /// Delete messages with confirmation.
  static Future<bool> confirmDelete(
    BuildContext context, {
    required int count,
    required bool canDeleteForEveryone,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count ${count == 1 ? 'message' : 'messages'}?'),
        content: Text(
          canDeleteForEveryone
              ? 'Delete for everyone or just for you?'
              : 'This will delete the message only for you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          if (canDeleteForEveryone) ...[
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('DELETE FOR ME'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('DELETE FOR EVERYONE'),
            ),
          ] else
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('DELETE'),
            ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Get available actions based on selection.
  static Set<MessageAction> getAvailableActions({
    required List<MessageCache> selectedMessages,
    required String currentUserId,
  }) {
    final actions = <MessageAction>{
      MessageAction.delete,
      MessageAction.star,
    };

    // Reply only works with single selection
    if (selectedMessages.length == 1) {
      actions.add(MessageAction.reply);
      actions.add(MessageAction.info);

      // Copy only available for text messages
      if (selectedMessages.first.messageType == 'text' ||
          selectedMessages.first.messageType == null) {
        actions.add(MessageAction.copy);
      }
    }

    // Forward works with any selection
    if (selectedMessages.isNotEmpty) {
      actions.add(MessageAction.forward);
    }

    // React works with single selection
    if (selectedMessages.length == 1) {
      actions.add(MessageAction.react);
    }

    return actions;
  }
}

enum MessageAction {
  reply,
  forward,
  copy,
  delete,
  star,
  react,
  info,
}

/// Message options sheet widget.
class _MessageOptionsSheet extends StatelessWidget {
  final bool isMe;
  final bool isText;
  final bool isStarred;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback? onCopy;
  final VoidCallback onDelete;
  final VoidCallback onStar;
  final VoidCallback onReact;
  final VoidCallback? onInfo;

  const _MessageOptionsSheet({
    required this.isMe,
    required this.isText,
    required this.isStarred,
    required this.onReply,
    required this.onForward,
    this.onCopy,
    required this.onDelete,
    required this.onStar,
    required this.onReact,
    this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildOption(
              icon: Icons.reply,
              label: 'Reply',
              onTap: onReply,
            ),
            _buildOption(
              icon: Icons.forward,
              label: 'Forward',
              onTap: onForward,
            ),
            if (onCopy != null)
              _buildOption(
                icon: Icons.copy,
                label: 'Copy',
                onTap: onCopy!,
              ),
            _buildOption(
              icon: Icons.star,
              label: isStarred ? 'Unstar' : 'Star',
              onTap: onStar,
            ),
            _buildOption(
              icon: Icons.emoji_emotions,
              label: 'React',
              onTap: onReact,
            ),
            if (onInfo != null)
              _buildOption(
                icon: Icons.info_outline,
                label: 'Info',
                onTap: onInfo!,
              ),
            const Divider(height: 1),
            _buildOption(
              icon: Icons.delete_outline,
              label: 'Delete',
              iconColor: Colors.red,
              textColor: Colors.red,
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    Color? textColor,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? Colors.grey.shade700),
      title: Text(
        label,
        style: TextStyle(color: textColor ?? Colors.black87),
      ),
      onTap: onTap,
    );
  }
}
