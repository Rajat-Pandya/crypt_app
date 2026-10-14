import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../widgets/reaction_popup.dart';

/// WhatsApp-style reaction model with proper Firestore serialization.
/// Handles type-safe parsing without runtime cast crashes.
/// 
/// NOTE: This is the UI-facing reaction model. For cache/Hive storage,
/// use MessageReaction from cache/models/message_cache.dart
class ReactionModel {
  final String emoji;
  final List<String> userIds;

  const ReactionModel({
    required this.emoji,
    required this.userIds,
  });

  /// Safely parse from Firestore data.
  /// Handles: Map<String, dynamic>, Map<String, List<dynamic>>, null.
  /// No runtime cast crashes - all types checked.
  static Map<String, List<String>> parseReactions(dynamic data) {
    if (data == null) return {};

    try {
      if (data is Map) {
        final result = <String, List<String>>{};
        for (final entry in data.entries) {
          final emoji = entry.key?.toString() ?? '';
          if (emoji.isEmpty) continue;
          
          final userList = entry.value;
          if (userList is List) {
            // Safely convert List<dynamic> to List<String>
            final users = userList
                .map((e) => e?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .toList();
            if (users.isNotEmpty) {
              result[emoji] = users;
            }
          }
        }
        return result;
      }
    } catch (e) {
      debugPrint('[ReactionModel] parseReactions error: $e');
    }

    return {};
  }

  /// Convert to Firestore-safe format.
  static Map<String, dynamic> toFirestore(Map<String, List<String>> reactions) {
    return Map<String, dynamic>.from(reactions);
  }

  /// Check if user has reacted with specific emoji.
  static bool hasUserReacted(
    Map<String, List<String>> reactions,
    String emoji,
    String userId,
  ) {
    final users = reactions[emoji];
    if (users == null) return false;
    return users.contains(userId);
  }

  /// Get total reaction count.
  static int getTotalCount(Map<String, List<String>> reactions) {
    return reactions.values.fold(0, (sum, users) => sum + users.length);
  }

  /// Get reactions for a specific user.
  static List<String> getUserReactions(
    Map<String, List<String>> reactions,
    String userId,
  ) {
    return reactions.entries
        .where((entry) => entry.value.contains(userId))
        .map((entry) => entry.key)
        .toList();
  }
}

/// Controller for managing message reactions with realtime sync.
class ReactionController extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  // Streams for realtime reaction updates per message
  final Map<String, StreamSubscription<DocumentSnapshot>> _reactionStreams = {};
  final Map<String, Map<String, List<String>>> _reactionsCache = {};
  final Map<String, ValueNotifier<Map<String, List<String>>>> _notifiers = {};

  /// Quick reaction emojis (WhatsApp-style).
  static const List<String> quickReactions = [
    '👍', // Like
    '❤️', // Love
    '😂', // Laugh
    '😮', // Wow
    '😢', // Sad
    '🙏', // Thanks
  ];

  /// Get or create a notifier for a message's reactions.
  ValueNotifier<Map<String, List<String>>> getReactionsNotifier(
    String roomId,
    String messageId,
  ) {
    final key = '${roomId}_$messageId';
    if (!_notifiers.containsKey(key)) {
      _notifiers[key] = ValueNotifier({});
      _subscribeToReactions(roomId, messageId);
    }
    return _notifiers[key]!;
  }

  /// Subscribe to realtime reaction updates.
  void _subscribeToReactions(String roomId, String messageId) {
    final key = '${roomId}_$messageId';
    if (_reactionStreams.containsKey(key)) return;

    final stream = _firestore
        .collection('chat_rooms')
        .doc(roomId)
        .collection('messages')
        .doc(messageId)
        .snapshots();

    _reactionStreams[key] = stream.listen((snapshot) {
      if (!snapshot.exists) return;
      
      final data = snapshot.data();
      if (data == null) return;

      final reactions = ReactionModel.parseReactions(data['reactions']);
      _reactionsCache[key] = reactions;
      
      // Update notifier without full rebuild
      if (_notifiers.containsKey(key)) {
        _notifiers[key]!.value = Map.unmodifiable(reactions);
      }
    });
  }

  /// Toggle a reaction for a message.
  Future<bool> toggleReaction({
    required String roomId,
    required String messageId,
    required String emoji,
    required String userId,
  }) async {
    try {
      HapticFeedback.lightImpact();
      
      final messageRef = _firestore
          .collection('chat_rooms')
          .doc(roomId)
          .collection('messages')
          .doc(messageId);

      // Use transaction for atomic update
      final result = await _firestore.runTransaction<bool>((transaction) async {
        final snapshot = await transaction.get(messageRef);
        if (!snapshot.exists) return false;

        final data = snapshot.data();
        if (data == null) return false;

        // Safely get current reactions with typed parsing
        final reactionsData = data['reactions'];
        final reactions = ReactionModel.parseReactions(reactionsData);

        // Toggle user in emoji list
        final users = List<String>.from(reactions[emoji] ?? []);
        final wasReacted = users.contains(userId);
        
        if (wasReacted) {
          users.remove(userId);
          if (users.isEmpty) {
            reactions.remove(emoji);
          } else {
            reactions[emoji] = users;
          }
        } else {
          users.add(userId);
          reactions[emoji] = users;
        }

        // Update with Firestore-safe format
        transaction.update(messageRef, {'reactions': reactions});
        
        return !wasReacted; // Return true if added, false if removed
      });

      notifyListeners();
      return result;
    } catch (e) {
      debugPrint('[ReactionController] toggleReaction error: $e');
      return false;
    }
  }

  /// Add a reaction (idempotent).
  Future<void> addReaction({
    required String roomId,
    required String messageId,
    required String emoji,
    required String userId,
  }) async {
    if (ReactionModel.hasUserReacted(
      _reactionsCache['${roomId}_$messageId'] ?? {},
      emoji,
      userId,
    )) {
      return; // Already reacted
    }
    await toggleReaction(
      roomId: roomId,
      messageId: messageId,
      emoji: emoji,
      userId: userId,
    );
  }

  /// Remove a reaction (idempotent).
  Future<void> removeReaction({
    required String roomId,
    required String messageId,
    required String emoji,
    required String userId,
  }) async {
    if (!ReactionModel.hasUserReacted(
      _reactionsCache['${roomId}_$messageId'] ?? {},
      emoji,
      userId,
    )) {
      return; // Not reacted
    }
    await toggleReaction(
      roomId: roomId,
      messageId: messageId,
      emoji: emoji,
      userId: userId,
    );
  }

  /// Get reactions for a message (from cache).
  Map<String, List<String>> getReactions(String roomId, String messageId) {
    return _reactionsCache['${roomId}_$messageId'] ?? {};
  }

  /// Dispose and cleanup streams.
  void disposeMessage(String roomId, String messageId) {
    final key = '${roomId}_$messageId';
    _reactionStreams.remove(key)?.cancel();
    _notifiers.remove(key)?.dispose();
    _reactionsCache.remove(key);
  }

  @override
  void dispose() {
    for (final stream in _reactionStreams.values) {
      stream.cancel();
    }
    _reactionStreams.clear();
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    _reactionsCache.clear();
    super.dispose();
  }

  /// Show reaction picker popup (WhatsApp-style).
  static void showReactionPicker({
    required BuildContext context,
    required GlobalKey bubbleKey,
    required Function(String) onReactionSelected,
    required String currentReaction,
  }) {
    HapticFeedback.mediumImpact();
    
    ReactionPopupUtils.show(
      context: context,
      anchorKey: bubbleKey,
      currentReaction: currentReaction,
      onReactionSelected: onReactionSelected,
    );
  }
}
