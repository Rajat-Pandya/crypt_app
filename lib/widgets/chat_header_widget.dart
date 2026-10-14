import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../services/chat_util_service.dart';
import '../services/chat_list_service.dart';
import '../utils/avatar_utils.dart';

/// A self-contained chat header widget that isolates typing indicator rebuilds.
///
/// This widget:
/// - Manages its own Firestore subscription for room metadata (typing, mute status)
/// - Uses ValueNotifier internally to minimize rebuild scope
/// - Prevents full Scaffold rebuilds when typing status changes
/// - Provides stable AppBar state with minimal coupling to parent
class ChatHeaderWidget extends StatefulWidget implements PreferredSizeWidget {
  final String receiverId;
  final String receiverName;
  final VoidCallback onGamePressed;
  final VoidCallback onSearchPressed;
  final VoidCallback onProfilePressed;
  final VoidCallback onClearChatPressed;
  final VoidCallback onToggleMutePressed;
  final VoidCallback onStarredMessagesPressed;

  const ChatHeaderWidget({
    super.key,
    required this.receiverId,
    required this.receiverName,
    required this.onGamePressed,
    required this.onSearchPressed,
    required this.onProfilePressed,
    required this.onClearChatPressed,
    required this.onToggleMutePressed,
    required this.onStarredMessagesPressed,
  });

  @override
  State<ChatHeaderWidget> createState() => _ChatHeaderWidgetState();
  
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _ChatHeaderWidgetState extends State<ChatHeaderWidget> {
  final currentUser = FirebaseAuth.instance.currentUser!;
  
  // Stream subscription for room metadata
  StreamSubscription<DocumentSnapshot>? _roomSubscription;
  
  // Cached values to prevent unnecessary rebuilds
  final ValueNotifier<bool> _isTypingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isMutedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String> _receiverNameNotifier = ValueNotifier<String>('');
  
  // Track if we have initial data
  bool _hasData = false;

  @override
  void initState() {
    super.initState();
    _receiverNameNotifier.value = widget.receiverName;
    _subscribeToRoom();
  }

  void _subscribeToRoom() {
    final roomId = ChatListService.getRoomId(currentUser.uid, widget.receiverId);
    
    // Check if room exists first
    FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(roomId)
        .get()
        .then((doc) {
      if (!mounted) return;
      
      if (doc.exists) {
        _setupRoomSubscription(roomId);
      }
    }).catchError((e) {
      _dbg('Failed to check room existence: $e');
    });
  }

  void _setupRoomSubscription(String roomId) {
    _roomSubscription?.cancel();
    
    _roomSubscription = FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(roomId)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted || !snapshot.exists) return;
        
        final data = snapshot.data();
        if (data == null) return;
        
        _hasData = true;
        
        // Update typing status
        final isTyping = data['typing_${widget.receiverId}'] ?? false;
        if (_isTypingNotifier.value != isTyping) {
          _isTypingNotifier.value = isTyping;
        }
        
        // Update mute status
        final isMuted = data['muted_${currentUser.uid}'] ?? false;
        if (_isMutedNotifier.value != isMuted) {
          _isMutedNotifier.value = isMuted;
        }
      },
      onError: (error) {
        _dbg('Room subscription error: $error');
      },
    );
  }

  @override
  void didUpdateWidget(ChatHeaderWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update receiver name if it changed
    if (oldWidget.receiverName != widget.receiverName) {
      _receiverNameNotifier.value = widget.receiverName;
    }
  }

  @override
  void dispose() {
    _roomSubscription?.cancel();
    _isTypingNotifier.dispose();
    _isMutedNotifier.dispose();
    _receiverNameNotifier.dispose();
    super.dispose();
  }

  void _dbg(String message) {
    assert(() {
      debugPrint('[ChatHeaderWidget] $message');
      return true;
    }());
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    
    return AppBar(
      backgroundColor: colors.appBarBg,
      elevation: 0,
      titleSpacing: 0,
      title: ValueListenableBuilder<String>(
        valueListenable: _receiverNameNotifier,
        builder: (context, receiverName, _) {
          return ValueListenableBuilder<bool>(
            valueListenable: _isMutedNotifier,
            builder: (context, isMuted, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: _isTypingNotifier,
                builder: (context, isTyping, _) {
                  return _buildTitleContent(
                    context,
                    receiverName,
                    isMuted,
                    isTyping,
                    colors,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTitleContent(
    BuildContext context,
    String receiverName,
    bool isMuted,
    bool isTyping,
    AppColors colors,
  ) {
    return Row(
      children: [
        const SizedBox(width: 8),
        CircleAvatar(
          radius: 18,
          backgroundColor: colors.accent,
          child: Text(
            getInitials(receiverName),
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      receiverName.isEmpty ? 'User' : receiverName,
                      style: TextStyle(
                        color: colors.primaryText,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isMuted) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.notifications_off,
                      size: 14,
                      color: Colors.grey,
                    ),
                  ],
                ],
              ),
              // Typing indicator - only shows when typing
              AnimatedOpacity(
                opacity: isTyping ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Text(
                  'typing...',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.accent,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildActions(context, isMuted, colors),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildActions(BuildContext context, bool isMuted, AppColors colors) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(Icons.sports_esports, color: colors.primaryText),
          tooltip: 'Play game',
          onPressed: widget.onGamePressed,
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: colors.primaryText),
          color: colors.cardBg,
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'profile',
              child: Text(
                'View profile',
                style: TextStyle(color: colors.primaryText),
              ),
            ),
            PopupMenuItem(
              value: 'search',
              child: Text(
                'Search',
                style: TextStyle(color: colors.primaryText),
              ),
            ),
            PopupMenuItem(
              value: 'mute',
              child: Text(
                isMuted ? 'Unmute notifications' : 'Mute notifications',
                style: TextStyle(color: colors.primaryText),
              ),
            ),
            PopupMenuItem(
              value: 'starred',
              child: Text(
                'Starred messages',
                style: TextStyle(color: colors.primaryText),
              ),
            ),
            const PopupMenuItem(
              value: 'clear',
              child: Text(
                'Clear chat',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
          onSelected: (value) {
            switch (value) {
              case 'search':
                widget.onSearchPressed();
              case 'profile':
                widget.onProfilePressed();
              case 'clear':
                widget.onClearChatPressed();
              case 'mute':
                widget.onToggleMutePressed();
              case 'starred':
                widget.onStarredMessagesPressed();
            }
          },
        ),
      ],
    );
  }
}

/// A lighter-weight version for use in places where you need
/// just the header content without the full AppBar
class ChatHeaderContent extends StatelessWidget {
  final String receiverName;
  final bool isTyping;
  final bool isMuted;
  final VoidCallback? onTap;

  const ChatHeaderContent({
    super.key,
    required this.receiverName,
    this.isTyping = false,
    this.isMuted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          const SizedBox(width: 8),
          CircleAvatar(
            radius: 18,
            backgroundColor: colors.accent,
            child: Text(
              getInitials(receiverName),
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        receiverName.isEmpty ? 'User' : receiverName,
                        style: TextStyle(
                          color: colors.primaryText,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isMuted) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.notifications_off,
                        size: 14,
                        color: Colors.grey,
                      ),
                    ],
                  ],
                ),
                AnimatedOpacity(
                  opacity: isTyping ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    'typing...',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.accent,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
