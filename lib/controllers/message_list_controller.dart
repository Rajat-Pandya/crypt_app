import 'package:flutter/material.dart';
import '../cache/models/message_cache.dart';

/// Controller for managing message list state with granular updates.
///
/// Uses ValueNotifier for specific message updates without rebuilding the entire list.
/// Note: Selection is now handled by MessageSelectionController.
class MessageListController extends ChangeNotifier {
  final List<MessageCache> _messages = [];
  final Map<String, MessageCache> _messageMap = {};
  String _searchQuery = '';

  // ValueNotifiers for granular updates
  final _typingNotifier = ValueNotifier<Map<String, bool>>({});
  final _searchNotifier = ValueNotifier<String>('');

  List<MessageCache> get messages => List.unmodifiable(_messages);
  Map<String, MessageCache> get messageMap => Map.unmodifiable(_messageMap);
  String get searchQuery => _searchQuery;

  ValueNotifier<Map<String, bool>> get typingNotifier => _typingNotifier;
  ValueNotifier<String> get searchNotifier => _searchNotifier;

  /// Update messages with diff calculation
  void updateMessages(List<MessageCache> newMessages) {
    final oldIds = _messageMap.keys.toSet();
    final newIds = newMessages.map((m) => m.messageId).toSet();

    // Find added, removed, and updated messages
    final added = newIds.difference(oldIds);
    final removed = oldIds.difference(newIds);
    final potentiallyUpdated = newIds.intersection(oldIds);

    // Only update if there are actual changes
    if (added.isEmpty && removed.isEmpty) {
      // Check for content updates in existing messages
      bool hasUpdates = false;
      for (final id in potentiallyUpdated) {
        final oldMsg = _messageMap[id]!;
        final newMsg = newMessages.firstWhere((m) => m.messageId == id);
        if (_messageChanged(oldMsg, newMsg)) {
          hasUpdates = true;
          break;
        }
      }
      if (!hasUpdates) return;
    }

    _messages.clear();
    _messages.addAll(newMessages);
    _messageMap.clear();
    for (final msg in _messages) {
      _messageMap[msg.messageId] = msg;
    }

    notifyListeners();
  }

  /// Check if message content changed (for diffing)
  bool _messageChanged(MessageCache old, MessageCache newMsg) {
    return old.status != newMsg.status ||
           old.starred != newMsg.starred ||
           old.reactions.toString() != newMsg.reactions.toString() ||
           old.deletedFor.toString() != newMsg.deletedFor.toString();
  }

  /// Set search query
  void setSearchQuery(String query) {
    if (_searchQuery != query) {
      _searchQuery = query;
      _searchNotifier.value = query;
      notifyListeners();
    }
  }

  /// Update typing status
  void updateTyping(Map<String, bool> typing) {
    _typingNotifier.value = Map.from(typing);
  }

  /// Get message by ID
  MessageCache? getMessage(String id) => _messageMap[id];

  /// Get message index
  int indexOf(String messageId) => _messages.indexWhere((m) => m.messageId == messageId);

  @override
  void dispose() {
    _typingNotifier.dispose();
    _searchNotifier.dispose();
    super.dispose();
  }
}

/// Data class for pre-computed message metadata to avoid recalculation in build
@immutable
class MessageMetadata {
  final String messageId;
  final bool showDate;
  final bool isLastInGroup;
  final String timeLabel;
  final DateTime? timestamp;

  const MessageMetadata({
    required this.messageId,
    required this.showDate,
    required this.isLastInGroup,
    required this.timeLabel,
    this.timestamp,
  });
}

/// Pre-computer for message metadata to optimize build performance
class MessageMetadataComputer {
  static List<MessageMetadata> computeMetadata(List<MessageCache> messages) {
    if (messages.isEmpty) return [];

    final metadata = <MessageMetadata>[];

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final timestamp = msg.timestamp;

      // Determine if we should show date
      bool showDate = i == 0;
      if (i > 0 && timestamp != null) {
        final prevTimestamp = messages[i - 1].timestamp;
        if (prevTimestamp != null) {
          final cur = timestamp;
          final prv = prevTimestamp;
          if (cur.day != prv.day || cur.month != prv.month || cur.year != prv.year) {
            showDate = true;
          }
        }
      }

      // Determine if last in group
      bool isLastInGroup = true;
      if (i < messages.length - 1) {
        isLastInGroup = messages[i + 1].senderId != msg.senderId;
      }

      // Format time
      String timeLabel = '';
      if (timestamp != null) {
        timeLabel = '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
      }

      metadata.add(MessageMetadata(
        messageId: msg.messageId,
        showDate: showDate,
        isLastInGroup: isLastInGroup,
        timeLabel: timeLabel,
        timestamp: timestamp,
      ));
    }

    return metadata;
  }
}
