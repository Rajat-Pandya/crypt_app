import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:flutter/services.dart';
import '../models/message_ui_state.dart';
import '../services/message_state_manager.dart';
import '../repositories/message_repository.dart';
import '../services/decrypt_queue_manager.dart';

/// Optimized message bubble with per-message state isolation.
/// 
/// Features:
/// - ValueNotifier-based granular rebuilds
/// - No full list rebuilds on edit/decrypt
/// - Automatic decrypt queueing
/// - Proper cache management
/// - FEATURE 1: Swipe-to-reply with haptic feedback
/// - FEATURE 2: Enhanced reply preview bubble
/// - FEATURE 4: Deleted-message fallback
class OptimizedMessageBubble extends StatefulWidget {
  final String messageId;
  final String senderId;
  final String currentUserId;
  final String encryptedText;
  final String? aesKey;
  final String? aesKeySender;
  final String? iv;
  final String? senderKeyVersion;
  final String? receiverKeyVersion;
  final Timestamp? timestamp;
  final Timestamp? editedAt;
  final Map<String, dynamic>? reactions;
  final Map<String, dynamic>? replyTo;
  final bool isStarred;
  final List<String> deletedFor;
  final String? status;
  final bool showDate;
  final String dateLabel;
  final RSAPrivateKey? privateKey;
  final RSAPrivateKey? senderPrivateKey;
  final double maxBubbleWidth;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final Widget Function(String plaintext, bool isEdited, DateTime? editedAt)?
      bubbleBuilder;
  
  // FEATURE 1 & 3: Callbacks for reply and jump functionality
  final VoidCallback? onReply;
  final VoidCallback? onReplyTap;
  final bool isDeletedForEveryone;

  const OptimizedMessageBubble({
    super.key,
    required this.messageId,
    required this.senderId,
    required this.currentUserId,
    required this.encryptedText,
    this.aesKey,
    this.aesKeySender,
    this.iv,
    this.senderKeyVersion,
    this.receiverKeyVersion,
    this.timestamp,
    this.editedAt,
    this.reactions,
    this.replyTo,
    this.isStarred = false,
    this.deletedFor = const [],
    this.status,
    this.showDate = false,
    this.dateLabel = '',
    this.privateKey,
    this.senderPrivateKey,
    required this.maxBubbleWidth,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
    this.bubbleBuilder,
    this.onReply,
    this.onReplyTap,
    this.isDeletedForEveryone = false,
  });

  bool get isMe => senderId == currentUserId;

  @override
  State<OptimizedMessageBubble> createState() => _OptimizedMessageBubbleState();
}

class _OptimizedMessageBubbleState extends State<OptimizedMessageBubble>
    with SingleTickerProviderStateMixin {
  late final ValueNotifier<MessageUIState> _stateNotifier;
  final _stateManager = MessageStateManager();
  final _repository = MessageRepository();
  StreamSubscription<String>? _decryptSubscription;
  
  // FEATURE 1: Swipe animation controller
  late AnimationController _swipeController;
  
  // Debug logging
  static void _dbg(String message) {
    assert(() {
      debugPrint('[OptimizedMessageBubble] $message');
      return true;
    }());
  }
  
  int _buildCount = 0;
  double _dragOffset = 0.0;
  static const double _maxDrag = 80.0;
  static const double _threshold = 60.0;
  bool _thresholdReached = false;

  @override
  void initState() {
    super.initState();
    _dbg('initState: ${widget.messageId}');
    
    // Initialize swipe animation controller
    _swipeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    // Initialize state
    _stateNotifier = _stateManager.getState(
      widget.messageId,
      initialState: _createInitialState(),
    );

    // Start decrypt if needed
    _ensureDecrypted();

    // Listen for decrypt completion from queue
    _decryptSubscription = DecryptQueueManager()
        .onDecryptComplete
        .listen((messageId) {
      if (messageId == widget.messageId) {
        _dbg('Decrypt complete received for ${widget.messageId}');
        _updateFromCache();
      }
    });
  }

  MessageUIState _createInitialState() {
    // Check repository cache first
    final cached = _repository.getCachedDecrypted(widget.messageId);
    if (cached != null) {
      return MessageUIState(
        id: widget.messageId,
        senderId: widget.senderId,
        plaintext: cached,
        isDecrypted: true,
        isDecrypting: false,
        isEdited: widget.editedAt != null,
        editedAt: widget.editedAt?.toDate(),
        timestamp: widget.timestamp,
        reactions: widget.reactions,
        replyTo: widget.replyTo,
        isStarred: widget.isStarred,
        deletedFor: widget.deletedFor,
        status: widget.status,
      );
    }

    return MessageUIState(
      id: widget.messageId,
      senderId: widget.senderId,
      plaintext: '🔒',
      isDecrypted: false,
      isDecrypting: true,
      isEdited: widget.editedAt != null,
      editedAt: widget.editedAt?.toDate(),
      timestamp: widget.timestamp,
      reactions: widget.reactions,
      replyTo: widget.replyTo,
      isStarred: widget.isStarred,
      deletedFor: widget.deletedFor,
      status: widget.status,
    );
  }

  void _ensureDecrypted() async {
    _dbg('ensureDecrypted: ${widget.messageId}, alreadyDecrypted=${_stateNotifier.value.isDecrypted}');
    if (_stateNotifier.value.isDecrypted) return;

    final privateKey = widget.isMe ? widget.senderPrivateKey : widget.privateKey;
    final aesKeyEncrypted =
        widget.isMe ? widget.aesKeySender : widget.aesKey;

    if (privateKey == null ||
        aesKeyEncrypted == null ||
        widget.iv == null) {
      _stateNotifier.value = _stateNotifier.value.copyWith(
        plaintext: '🔒',
        isDecrypting: false,
      );
      return;
    }

    try {
      await _repository.decryptMessage(
        messageId: widget.messageId,
        encryptedText: widget.encryptedText,
        aesKeyEncrypted: aesKeyEncrypted,
        iv: widget.iv!,
        privateKey: privateKey,
      );

      // Update from cache after decrypt
      _updateFromCache();
    } catch (e) {
      _stateNotifier.value = _stateNotifier.value.copyWith(
        plaintext: '🔒',
        isDecrypting: false,
        error: 'Decrypt failed',
      );
    }
  }

  void _updateFromCache() {
    final cached = _repository.getCachedDecrypted(widget.messageId);
    if (cached != null && mounted) {
      _stateNotifier.value = _stateNotifier.value.copyWith(
        plaintext: cached,
        isDecrypted: true,
        isDecrypting: false,
      );
    }
  }

  @override
  void didUpdateWidget(covariant OptimizedMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update state if reactions changed
    if (widget.reactions != oldWidget.reactions) {
      _stateNotifier.value = _stateNotifier.value.copyWith(
        reactions: widget.reactions,
      );
    }

    // Update if edit completed
    if (widget.editedAt != oldWidget.editedAt && widget.editedAt != null) {
      _repository.clearCachedDecrypted(widget.messageId);
      _ensureDecrypted();
    }
  }

  @override
  void dispose() {
    _dbg('dispose: ${widget.messageId}');
    _decryptSubscription?.cancel();
    _stateManager.scheduleCleanup(widget.messageId);
    _swipeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    if (_buildCount % 50 == 0) {
      _dbg('build #$_buildCount: ${widget.messageId}');
    }
    
    return ValueListenableBuilder<MessageUIState>(
      valueListenable: _stateNotifier,
      builder: (context, state, child) {
        return _buildBubble(context, state);
      },
    );
  }

  // FEATURE 1: Handle horizontal drag for swipe-to-reply
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    // Only allow swipe in one direction based on message owner
    // Swipe right for received messages (isMe = false), left for sent (isMe = true)
    final isMe = widget.isMe;
    
    if (isMe) {
      // For sent messages, allow swiping left (negative delta)
      if (details.delta.dx < 0) {
        setState(() {
          _dragOffset = (_dragOffset + details.delta.dx).clamp(-_maxDrag, 0.0);
          _checkThreshold();
        });
      }
    } else {
      // For received messages, allow swiping right (positive delta)
      if (details.delta.dx > 0) {
        setState(() {
          _dragOffset = (_dragOffset + details.delta.dx).clamp(0.0, _maxDrag);
          _checkThreshold();
        });
      }
    }
  }

  void _checkThreshold() {
    final reached = _dragOffset.abs() >= _threshold;
    if (reached != _thresholdReached) {
      _thresholdReached = reached;
      if (reached) {
        // Haptic feedback on threshold
        HapticFeedback.lightImpact();
      }
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_thresholdReached && widget.onReply != null) {
      // Trigger reply
      widget.onReply!();
    }
    
    // Spring back animation
    _swipeController.forward(from: 0.0).then((_) {
      setState(() {
        _dragOffset = 0.0;
        _thresholdReached = false;
      });
      _swipeController.reset();
    });
  }

  Widget _buildBubble(BuildContext context, MessageUIState state) {
    // Use custom builder if provided
    if (widget.bubbleBuilder != null) {
      return widget.bubbleBuilder!(state.plaintext, state.isEdited, state.editedAt);
    }

    // Check if deleted for current user
    if (state.deletedFor.contains(widget.currentUserId)) {
      return const SizedBox.shrink();
    }

    final isMe = widget.isMe;
    final colors = Theme.of(context).colorScheme;
    final time = widget.timestamp != null
        ? '${widget.timestamp!.toDate().hour.toString().padLeft(2, '0')}:${widget.timestamp!.toDate().minute.toString().padLeft(2, '0')}'
        : '';

    // FEATURE 1: Wrap with GestureDetector for swipe
    Widget bubbleContent = GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: widget.isSelected
            ? colors.primary.withOpacity(0.12)
            : Colors.transparent,
        padding: EdgeInsets.only(
          left: isMe ? 0 : (widget.isSelected ? 4 : 0),
          right: isMe ? (widget.isSelected ? 4 : 0) : 0,
        ),
        child: Column(
          children: [
            if (widget.showDate)
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    widget.dateLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurface.withOpacity(0.6),
                    ),
                  ),
                ),
              ),
            // FEATURE 1: Stack for swipe icon overlay
            Stack(
              children: [
                // Main bubble
                Container(
                  margin: EdgeInsets.only(
                    top: 14,
                    bottom: 2,
                    left: isMe ? 50 : (widget.isSelected ? 36 : 10),
                    right: isMe ? (widget.isSelected ? 36 : 10) : 50,
                  ),
                  child: Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: widget.maxBubbleWidth),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        // FEATURE 4: Muted background for deleted messages
                        color: widget.isDeletedForEveryone
                            ? Colors.grey.withOpacity(0.3)
                            : isMe
                                ? colors.primary.withOpacity(0.9)
                                : colors.surface,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: isMe
                              ? const Radius.circular(16)
                              : const Radius.circular(4),
                          bottomRight: isMe
                              ? const Radius.circular(4)
                              : const Radius.circular(16),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // FEATURE 2: Reply preview (quoted block)
                          if (state.replyTo != null) ...[
                            GestureDetector(
                              onTap: widget.onReplyTap,
                              child: _buildReplyPreview(state.replyTo!, colors, isMe),
                            ),
                          ],
                          // FEATURE 4: Deleted message content
                          if (widget.isDeletedForEveryone) ...[
                            Text(
                              'This message was deleted',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade600,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ] else ...[
                            // Normal message text
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Flexible(
                                  child: Text(
                                    state.plaintext,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: isMe ? Colors.white : colors.onSurface,
                                    ),
                                  ),
                                ),
                                if (state.isStarred) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.star,
                                    size: 14,
                                    color: Colors.amber,
                                  ),
                                ],
                              ],
                            ),
                          ],
                          const SizedBox(height: 4),
                          // Time and edit indicator
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                time,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isMe
                                      ? Colors.white.withOpacity(0.7)
                                      : colors.onSurface.withOpacity(0.5),
                                ),
                              ),
                              if (state.isEdited && !widget.isDeletedForEveryone) ...[
                                const SizedBox(width: 4),
                                Text(
                                  'edited',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isMe
                                        ? Colors.white.withOpacity(0.6)
                                        : colors.onSurface.withOpacity(0.4),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                              const SizedBox(width: 4),
                              if (isMe) _buildStatusIcon(state.status, isMe, colors),
                            ],
                          ),
                          // Reactions (hidden for deleted messages)
                          if (!widget.isDeletedForEveryone && state.hasReactions) ...[
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 4,
                              children: state.reactions!.entries.map((e) {
                                final count = (e.value as List).length;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colors.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: colors.outline,
                                    ),
                                  ),
                                  child: Text('${e.key} $count'),
                                );
                              }).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // FEATURE 1: Swipe reply icon
                if (_dragOffset.abs() > 10)
                  Positioned(
                    left: isMe ? null : _dragOffset,
                    right: isMe ? _dragOffset.abs() : null,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Opacity(
                        opacity: (_dragOffset.abs() / _maxDrag).clamp(0.0, 1.0),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: _thresholdReached
                                ? colors.primary
                                : colors.surface,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.reply,
                            color: _thresholdReached
                                ? Colors.white
                                : colors.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );

    // Apply transform for swipe animation
    return Transform.translate(
      offset: Offset(_dragOffset, 0),
      child: bubbleContent,
    );
  }

  // FEATURE 2: Build reply preview widget
  Widget _buildReplyPreview(Map<String, dynamic> replyTo, ColorScheme colors, bool isMe) {
    final preview = replyTo['preview'] as String?;
    final isDeleted = replyTo['isDeleted'] == true;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.white.withOpacity(0.15)
            : Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: isMe ? Colors.white70 : colors.primary,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Replying to',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: isMe
                  ? Colors.white.withOpacity(0.8)
                  : colors.primary.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            isDeleted
                ? 'Original message deleted'
                : (preview?.length ?? 0) > 60
                    ? '${preview!.substring(0, 60)}…'
                    : (preview ?? '...'),
            style: TextStyle(
              fontSize: 12,
              color: isDeleted
                  ? Colors.grey
                  : isMe
                      ? Colors.white.withOpacity(0.9)
                      : colors.onSurface.withOpacity(0.8),
              fontStyle: isDeleted ? FontStyle.italic : FontStyle.normal,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(String? status, bool isMe, ColorScheme colors) {
    IconData icon;
    Color color;

    switch (status) {
      case 'seen':
        icon = Icons.done_all;
        color = isMe ? Colors.white : colors.primary;
        break;
      case 'delivered':
        icon = Icons.done_all;
        color = isMe
            ? Colors.white.withOpacity(0.7)
            : colors.onSurface.withOpacity(0.5);
        break;
      case 'sent':
        icon = Icons.check;
        color = isMe
            ? Colors.white.withOpacity(0.7)
            : colors.onSurface.withOpacity(0.5);
        break;
      default:
        icon = Icons.schedule;
        color = isMe
            ? Colors.white.withOpacity(0.5)
            : colors.onSurface.withOpacity(0.3);
    }

    return Icon(icon, size: 14, color: color);
  }
}
