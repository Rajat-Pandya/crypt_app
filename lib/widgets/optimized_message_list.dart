import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:pointycastle/asymmetric/api.dart';
import '../repositories/message_repository.dart';
import '../services/decrypt_queue_manager.dart';
import '../widgets/optimized_message_bubble.dart';

/// Optimized message list with:
/// - No build-phase decrypt scheduling
/// - Per-message state isolation
/// - Distinct stream filtering
/// - Throttled emissions
class OptimizedMessageList extends StatefulWidget {
  final String chatRoomId;
  final String currentUserId;
  final String receiverId;
  final RSAPrivateKey? privateKey;
  final RSAPrivateKey? senderPrivateKey;
  final String? myKeyVersion;
  final int limit;
  final dynamic startAfter;
  final void Function(Message message)? onMessageTap;
  final void Function(Message message)? onMessageLongPress;
  final void Function(Message message, String decryptedText)? onEdit;
  final void Function(Message message)? onReply;
  final void Function(List<Message> messages)? onForward;
  final Set<String> selectedIds;
  final bool isSelecting;
  final String searchQuery;

  const OptimizedMessageList({
    super.key,
    required this.chatRoomId,
    required this.currentUserId,
    required this.receiverId,
    this.privateKey,
    this.senderPrivateKey,
    this.myKeyVersion,
    this.limit = 50,
    this.startAfter,
    this.onMessageTap,
    this.onMessageLongPress,
    this.onEdit,
    this.onReply,
    this.onForward,
    this.selectedIds = const {},
    this.isSelecting = false,
    this.searchQuery = '',
  });

  @override
  State<OptimizedMessageList> createState() => _OptimizedMessageListState();
}

class _OptimizedMessageListState extends State<OptimizedMessageList> {
  final _repository = MessageRepository();
  final _decryptQueue = DecryptQueueManager();
  final _scrollController = ScrollController();
  
  StreamSubscription<List<Message>>? _messagesSubscription;
  List<Message> _messages = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _rebuildCount = 0;

  @override
  void initState() {
    super.initState();
    _subscribeToMessages();
  }

  void _subscribeToMessages() {
    _messagesSubscription = _repository
        .getMessagesStream(
          chatRoomId: widget.chatRoomId,
          limit: widget.limit,
          startAfter: widget.startAfter,
        )
        .listen(
          (messages) {
            if (!mounted) return;
            
            _rebuildCount++;
            if (_rebuildCount % 10 == 0) {
              debugPrint('[OptimizedMessageList] Rebuild #$_rebuildCount, ${messages.length} messages');
            }
            
            setState(() {
              _messages = messages;
              _isLoading = false;
              _hasMore = messages.length >= widget.limit;
            });
          },
          onError: (e) {
            debugPrint('[OptimizedMessageList] Error: $e');
          },
        );
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  String _formatDate(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate();
    final now = DateTime.now();
    
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Today';
    }
    
    final yesterday = now.subtract(const Duration(days: 1));
    if (date.year == yesterday.year && date.month == yesterday.month && date.day == yesterday.day) {
      return 'Yesterday';
    }
    
    return '${date.day}/${date.month}/${date.year}';
  }

  bool _shouldShowDate(int index) {
    if (index == 0) return true;
    
    final current = _messages[index].timestamp?.toDate();
    final previous = _messages[index - 1].timestamp?.toDate();
    
    if (current == null || previous == null) return false;
    
    return current.day != previous.day ||
           current.month != previous.month ||
           current.year != previous.year;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.75;

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      itemCount: _messages.length,
      cacheExtent: 500,
      itemBuilder: (context, index) {
        final message = _messages[index];
        
        // Skip deleted messages
        if (message.deletedFor.contains(widget.currentUserId)) {
          return const SizedBox.shrink();
        }

        // Filter by search
        final plaintext = _repository.getCachedDecrypted(message.id) ?? '';
        if (widget.searchQuery.isNotEmpty &&
            !plaintext.toLowerCase().contains(widget.searchQuery.toLowerCase())) {
          return const SizedBox.shrink();
        }

        final showDate = _shouldShowDate(index);

        return OptimizedMessageBubble(
          key: ValueKey(message.id),
          messageId: message.id,
          senderId: message.senderId,
          currentUserId: widget.currentUserId,
          encryptedText: message.text,
          aesKey: message.aesKey,
          aesKeySender: message.aesKeySender,
          iv: message.iv,
          senderKeyVersion: message.senderKeyVersion,
          receiverKeyVersion: message.receiverKeyVersion,
          timestamp: message.timestamp,
          editedAt: message.editedAt,
          reactions: message.reactions,
          replyTo: message.replyTo,
          isStarred: message.starred,
          deletedFor: message.deletedFor,
          status: message.status,
          showDate: showDate,
          dateLabel: showDate ? _formatDate(message.timestamp) : '',
          privateKey: widget.privateKey,
          senderPrivateKey: widget.senderPrivateKey,
          maxBubbleWidth: maxBubbleWidth,
          isSelected: widget.selectedIds.contains(message.id),
          onTap: widget.onMessageTap != null
              ? () => widget.onMessageTap!(message)
              : null,
          onLongPress: widget.onMessageLongPress != null
              ? () => widget.onMessageLongPress!(message)
              : null,
        );
      },
    );
  }
}
