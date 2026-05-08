import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/chat_list_service.dart';
import '../services/chat_service.dart';
import '../utils/avatar_utils.dart';
import '../main.dart';
import 'chat_screen.dart' show ChatScreen;
import 'user_list_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with WidgetsBindingObserver {
  final currentUser = FirebaseAuth.instance.currentUser!;

  String searchQuery = "";

  Stream<QuerySnapshot>? _chatRoomsStream;

  final Map<String, Map<String, dynamic>> _userDataCache = {};
  final Map<String, int> _unreadCountCache = {};
  final Set<String> _loadedUserIds = {};

  final Set<String> _selectedChats = {};

  bool get _isSelecting => _selectedChats.isNotEmpty;

  DateTime? _lastDeliveredMarkTime;

  // ── Internal debug helper ──────────────────────────────────────────────
  static void _dbg(String message) {
    assert(() {
      debugPrint('[ChatList] $message');
      return true;
    }());
  }

  // ────────────────────────────────────────────────────────────────────────

  String getRoomId(String u1, String u2) => ChatListService.getRoomId(u1, u2);

  // ── Lifecycle ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chatRoomsStream = ChatListService.getChatRooms(currentUser.uid);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markAllDeliveredDebounced();
    });
  }

  Future<void> _preloadChatData(List<DocumentSnapshot> docs) async {
    final userIdsToLoad = <String>{};

    for (final doc in docs) {
      final chatData = doc.data() as Map<String, dynamic>;
      final users = List<String>.from(chatData["users"] ?? []);
      for (final userId in users) {
        if (userId != currentUser.uid && !_loadedUserIds.contains(userId)) {
          userIdsToLoad.add(userId);
        }
      }
    }

    if (userIdsToLoad.isEmpty) return;

    for (final userId in userIdsToLoad) {
      if (_loadedUserIds.contains(userId)) continue;

      try {
        final userDoc = await FirebaseFirestore.instance
            .collection("users")
            .doc(userId)
            .get();

        if (userDoc.exists && userDoc.data() != null) {
          _userDataCache[userId] = userDoc.data()!;
          _loadedUserIds.add(userId);
          _dbg('preloaded user data for $userId');
        }
      } catch (e) {
        _dbg('failed to preload user $userId: ${e.runtimeType}');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _markAllDeliveredDebounced();
    }
  }

  // ── Delivered marking ──────────────────────────────────────────────────

  Future<void> _markAllDeliveredDebounced() async {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastDeliveredMarkTime != null &&
        now.difference(_lastDeliveredMarkTime!).inSeconds < 5) {
      return;
    }
    _lastDeliveredMarkTime = now;
    await _markAllDelivered();
  }

  Future<void> _markAllDelivered() async {
    if (!mounted) return;
    try {
      final rooms = await FirebaseFirestore.instance
          .collection("chat_rooms")
          .where("users", arrayContains: currentUser.uid)
          .get();

      for (final room in rooms.docs) {
        final roomData = room.data();
        final users = List<String>.from(roomData["users"] ?? []);
        final otherUserId = users.firstWhere(
          (id) => id != currentUser.uid,
          orElse: () => "",
        );
        if (otherUserId.isEmpty) continue;
        await ChatService.markMessagesAsDelivered(currentUser.uid, otherUserId);
      }

      _dbg('markAllDelivered: processed ${rooms.docs.length} rooms');
    } catch (e) {
      _dbg('markAllDelivered: failed — ${e.runtimeType}');
    }
  }

  // ── Snack helpers ──────────────────────────────────────────────────────

  void _showSnack(String message, {Color? color, Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _showLoadingSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Text(message),
          ],
        ),
        duration: const Duration(seconds: 30),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── Selection ──────────────────────────────────────────────────────────

  void _clearSelection() => setState(() => _selectedChats.clear());

  void _toggleSelection(String otherUserId) {
    setState(() {
      if (_selectedChats.contains(otherUserId)) {
        _selectedChats.remove(otherUserId);
      } else {
        _selectedChats.add(otherUserId);
      }
    });
  }

  // ── Subcollection deletion ─────────────────────────────────────────────

  Future<void> _deleteSubcollection(CollectionReference ref) async {
    const batchSize = 100;
    int deletedTotal = 0;

    while (true) {
      QuerySnapshot snapshot;
      try {
        snapshot = await ref.limit(batchSize).get();
      } catch (e) {
        _dbg('deleteSubcollection: fetch failed — ${e.runtimeType}');
        break;
      }

      if (snapshot.docs.isEmpty) break;

      try {
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in snapshot.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        deletedTotal += snapshot.docs.length;
      } catch (e) {
        _dbg('deleteSubcollection: batch failed, trying individually');
        int fallbackDeleted = 0;
        for (final doc in snapshot.docs) {
          try {
            await doc.reference.delete();
            fallbackDeleted++;
          } catch (e2) {
            _dbg(
              'deleteSubcollection: single delete failed — ${e2.runtimeType}',
            );
          }
        }
        deletedTotal += fallbackDeleted;
      }

      if (snapshot.docs.length < batchSize) break;
    }

    _dbg('deleteSubcollection: deleted $deletedTotal documents');
  }

  // ── Delete single chat room ────────────────────────────────────────────

  Future<void> _deleteChatRoom(String roomId) async {
    final roomRef = FirebaseFirestore.instance
        .collection("chat_rooms")
        .doc(roomId);

    final roomSnap = await roomRef.get();
    if (!roomSnap.exists) {
      _dbg('deleteChatRoom: room not found — already deleted');
      return;
    }

    final roomData = roomSnap.data();
    final users = List<String>.from(roomData?["users"] ?? []);

    if (!users.contains(currentUser.uid)) {
      throw Exception("Not a participant of this chat");
    }

    _dbg('deleteChatRoom: deleting messages subcollection');
    await _deleteSubcollection(roomRef.collection("messages"));

    _dbg('deleteChatRoom: deleting game subcollection');
    await _deleteSubcollection(roomRef.collection("game"));

    _dbg('deleteChatRoom: deleting room document');
    try {
      await roomRef.delete();
      _dbg('deleteChatRoom: complete');
    } catch (e) {
      _dbg('deleteChatRoom: room doc delete failed — ${e.runtimeType}');
      rethrow;
    }
  }

  // ── Delete selected chats ──────────────────────────────────────────────

  Future<void> _deleteSelectedChats() async {
    final colors = AppColors.of(context);
    final count = _selectedChats.length;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          "Delete $count Chat${count > 1 ? 's' : ''}?",
          style: TextStyle(color: colors.primaryText),
        ),
        content: Text(
          "This will permanently delete the selected "
          "conversation${count > 1 ? 's' : ''} and all messages. "
          "This cannot be undone.",
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text("Cancel", style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final toDelete = Set<String>.from(_selectedChats);
    _clearSelection();

    _showLoadingSnack("Deleting $count chat${count > 1 ? 's' : ''}...");

    int failed = 0;
    for (final otherUserId in toDelete) {
      final roomId = getRoomId(currentUser.uid, otherUserId);
      try {
        await _deleteChatRoom(roomId);
      } catch (e) {
        _dbg('deleteSelectedChats: one deletion failed — ${e.runtimeType}');
        failed++;
      }
    }

    if (failed == 0) {
      _showSnack(
        "Deleted $count chat${count > 1 ? 's' : ''}",
        color: Colors.green,
        duration: const Duration(seconds: 2),
      );
    } else {
      _showSnack(
        "$failed deletion${failed > 1 ? 's' : ''} failed. Try again.",
        color: Colors.red,
      );
    }
  }

  // ── Pin / Unpin selected chats ─────────────────────────────────────────

  Future<void> _pinSelectedChats(
    List<Map<String, dynamic>> allChatsData,
  ) async {
    final allPinned =
        _selectedChats.isNotEmpty &&
        _selectedChats.every((otherUserId) {
          final chatData = allChatsData.firstWhere((d) {
            final users = List<String>.from(d["users"] ?? []);
            return users.contains(otherUserId);
          }, orElse: () => {});
          final pinnedBy = List<String>.from(chatData["pinnedBy"] ?? []);
          return pinnedBy.contains(currentUser.uid);
        });

    final toProcess = Set<String>.from(_selectedChats);
    _clearSelection();

    int failed = 0;
    for (final otherUserId in toProcess) {
      final roomId = getRoomId(currentUser.uid, otherUserId);
      final roomRef = FirebaseFirestore.instance
          .collection("chat_rooms")
          .doc(roomId);
      try {
        await roomRef.update({
          "pinnedBy": allPinned
              ? FieldValue.arrayRemove([currentUser.uid])
              : FieldValue.arrayUnion([currentUser.uid]),
        });
      } catch (e) {
        _dbg('pinSelectedChats: one update failed — ${e.runtimeType}');
        failed++;
      }
    }

    if (failed == 0) {
      _showSnack(
        allPinned ? "Unpinned" : "Pinned",
        duration: const Duration(seconds: 2),
      );
    } else {
      _showSnack(
        "$failed pin${failed > 1 ? 's' : ''} failed.",
        color: Colors.red,
      );
    }
  }

  // ── Logout ─────────────────────────────────────────────────────────────

  Future<void> _handleLogout() async {
    final colors = AppColors.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("Log Out", style: TextStyle(color: colors.primaryText)),
        content: Text(
          "Are you sure you want to log out?",
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text("Cancel", style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Log Out", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _dbg('logout confirmed');
      await AuthService.logout(context);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _clearSelection();
      },
      child: Scaffold(
        backgroundColor: colors.screenBg,
        appBar: _isSelecting
            ? _buildSelectionAppBar(colors)
            : _buildNormalAppBar(colors),
        body: Column(
          children: [
            if (!_isSelecting)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: TextField(
                    style: TextStyle(color: colors.primaryText),
                    decoration: InputDecoration(
                      icon: Icon(Icons.search, color: colors.secondaryText),
                      hintText: "Search chats...",
                      hintStyle: TextStyle(color: colors.hintText),
                      border: InputBorder.none,
                    ),
                    onChanged: (value) =>
                        setState(() => searchQuery = value.toLowerCase()),
                  ),
                ),
              ),

            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: ChatListService.getChatRooms(currentUser.uid),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return Center(
                      child: CircularProgressIndicator(color: colors.accent),
                    );
                  }

                  if (snapshot.data!.docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: colors.hintText,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            "No chats yet",
                            style: TextStyle(
                              fontSize: 16,
                              color: colors.secondaryText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "Tap the edit icon to start a conversation",
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.hintText,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  final allDocs = snapshot.data!.docs;
                  final allChatsData = allDocs
                      .map((d) => d.data() as Map<String, dynamic>)
                      .toList();

                  // Preload user data in background
                  if (_loadedUserIds.isEmpty && allDocs.isNotEmpty) {
                    _preloadChatData(allDocs);
                  }

                  // ── Sort: pinned first, then by lastMessageTime ──────
                  final sortedDocs = [...allDocs];
                  sortedDocs.sort((a, b) {
                    final aData = a.data() as Map<String, dynamic>;
                    final bData = b.data() as Map<String, dynamic>;

                    final aPinned = List<String>.from(
                      aData["pinnedBy"] ?? [],
                    ).contains(currentUser.uid);
                    final bPinned = List<String>.from(
                      bData["pinnedBy"] ?? [],
                    ).contains(currentUser.uid);

                    if (aPinned && !bPinned) return -1;
                    if (!aPinned && bPinned) return 1;

                    final aTime =
                        (aData["lastMessageTime"] as Timestamp?)
                            ?.millisecondsSinceEpoch ??
                        0;
                    final bTime =
                        (bData["lastMessageTime"] as Timestamp?)
                            ?.millisecondsSinceEpoch ??
                        0;
                    return bTime.compareTo(aTime);
                  });

                  return ListView.builder(
                    itemCount: sortedDocs.length,
                    itemBuilder: (context, index) {
                      final chatData =
                          sortedDocs[index].data() as Map<String, dynamic>;
                      final users = List<String>.from(chatData["users"]);
                      final otherUserId = users.firstWhere(
                        (id) => id != currentUser.uid,
                      );
                      final roomId = getRoomId(currentUser.uid, otherUserId);
                      final isPinned = List<String>.from(
                        chatData["pinnedBy"] ?? [],
                      ).contains(currentUser.uid);
                      final isSelected = _selectedChats.contains(otherUserId);

                      // ── Fix 2: safe Timestamp cast ───────────────────
                      // Previously dynamic — could throw if Firestore
                      // returns unexpected type or null
                      final lastSeen =
                          chatData["lastSeen_${currentUser.uid}"] is Timestamp
                          ? chatData["lastSeen_${currentUser.uid}"] as Timestamp
                          : Timestamp(0, 0);
                      // ────────────────────────────────────────────────

                      final cachedUserData = _userDataCache[otherUserId];
                      String name = cachedUserData?["name"] as String? ?? "User";
                      bool isOnline = false;
                      if (cachedUserData != null) {
                        final isOnlineField =
                            cachedUserData["isOnline"] as bool? ?? false;
                        if (isOnlineField) {
                          final lastSeenUser =
                              cachedUserData["lastSeen"] as Timestamp?;
                          if (lastSeenUser != null) {
                            final diff = DateTime.now()
                                .difference(lastSeenUser.toDate())
                                .inSeconds;
                            if (diff < 20) isOnline = true;
                          }
                        }
                      }

                      if (searchQuery.isNotEmpty &&
                          !name.toLowerCase().contains(searchQuery)) {
                        return const SizedBox.shrink();
                      }

                      String timeLabel = "";
                      final lastMessageTime =
                          chatData["lastMessageTime"] as Timestamp?;
                      if (lastMessageTime != null) {
                        final dt = lastMessageTime.toDate();
                        final now = DateTime.now();
                        final isToday =
                            dt.day == now.day &&
                            dt.month == now.month &&
                            dt.year == now.year;
                        if (isToday) {
                          timeLabel =
                              "${dt.hour.toString().padLeft(2, '0')}:"
                              "${dt.minute.toString().padLeft(2, '0')}";
                        } else {
                          timeLabel =
                              "${dt.day}/${dt.month}/${dt.year}";
                        }
                      }

                      final unreadCount = _unreadCountCache[roomId] ?? 0;

                      return _buildChatTile(
                        context: context,
                        colors: colors,
                        name: name,
                        isOnline: isOnline,
                        unreadCount: unreadCount,
                        timeLabel: timeLabel,
                        lastMessage:
                            chatData["lastMessage"] as String? ??
                            "Encrypted message",
                        otherUserId: otherUserId,
                        isPinned: isPinned,
                        isSelected: isSelected,
                        allChatsData: allChatsData,
                        lastSentStatus: null,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── AppBars ────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildNormalAppBar(AppColors colors) {
    return AppBar(
      backgroundColor: colors.appBarBg,
      elevation: 0,
      title: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFF3B82F6),
            child: Icon(Icons.chat, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Text(
            "Chats",
            style: TextStyle(
              color: colors.primaryText,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.edit, color: colors.primaryText),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const UserListScreen()),
          ),
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: colors.primaryText),
          color: colors.cardBg,
          onSelected: (value) async {
            switch (value) {
              case "profile":
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              case "settings":
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              case "logout":
                await _handleLogout();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: "profile",
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 18,
                    color: colors.secondaryText,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    "My Profile",
                    style: TextStyle(color: colors.primaryText),
                  ),
                ],
              ),
            ),
            PopupMenuItem(
              value: "settings",
              child: Row(
                children: [
                  Icon(
                    Icons.settings_outlined,
                    size: 18,
                    color: colors.secondaryText,
                  ),
                  const SizedBox(width: 10),
                  Text("Settings", style: TextStyle(color: colors.primaryText)),
                ],
              ),
            ),
            const PopupMenuItem(
              value: "logout",
              child: Row(
                children: [
                  Icon(Icons.logout, size: 18, color: Colors.red),
                  SizedBox(width: 10),
                  Text("Log Out", style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar(AppColors colors) {
    return AppBar(
      backgroundColor: colors.appBarBg,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.close, color: colors.primaryText),
        onPressed: _clearSelection,
      ),
      title: Text(
        "${_selectedChats.length} selected",
        style: TextStyle(
          color: colors.primaryText,
          fontWeight: FontWeight.w600,
          fontSize: 18,
        ),
      ),
      actions: [
        StreamBuilder<QuerySnapshot>(
          stream: ChatListService.getChatRooms(currentUser.uid),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return IconButton(
                icon: Icon(Icons.push_pin_outlined, color: colors.primaryText),
                onPressed: null,
              );
            }

            final allChatsData = snapshot.data!.docs
                .map((d) => d.data() as Map<String, dynamic>)
                .toList();

            final allPinned =
                _selectedChats.isNotEmpty &&
                _selectedChats.every((otherUserId) {
                  final chatData = allChatsData.firstWhere((d) {
                    final users = List<String>.from(d["users"] ?? []);
                    return users.contains(otherUserId);
                  }, orElse: () => {});
                  final pinnedBy = List<String>.from(
                    chatData["pinnedBy"] ?? [],
                  );
                  return pinnedBy.contains(currentUser.uid);
                });

            return IconButton(
              icon: Icon(
                allPinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: allPinned ? colors.accent : colors.primaryText,
              ),
              tooltip: allPinned ? "Unpin" : "Pin",
              onPressed: () => _pinSelectedChats(allChatsData),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          tooltip: "Delete",
          onPressed: _deleteSelectedChats,
        ),
      ],
    );
  }

  // ── Tick icon ──────────────────────────────────────────────────────────

  Widget _buildTickIcon(String? status, AppColors colors) {
    if (status == null) return const SizedBox.shrink();
    return switch (status) {
      'seen' => Icon(Icons.done_all, size: 15, color: colors.accent),
      'delivered' => Icon(
        Icons.done_all,
        size: 15,
        color: colors.secondaryText,
      ),
      _ => Icon(Icons.check, size: 15, color: colors.secondaryText),
    };
  }

  // ── Chat tile ──────────────────────────────────────────────────────────

  Widget _buildChatTile({
    required BuildContext context,
    required AppColors colors,
    required String name,
    required bool isOnline,
    required int unreadCount,
    required String timeLabel,
    required String lastMessage,
    required String otherUserId,
    required bool isPinned,
    required bool isSelected,
    required List<Map<String, dynamic>> allChatsData,
    String? lastSentStatus,
  }) {
    final bool hasUnread = unreadCount > 0;

    return InkWell(
      onTap: () {
        if (_isSelecting) {
          _toggleSelection(otherUserId);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(receiverId: otherUserId),
            ),
          );
        }
      },
      onLongPress: () => _toggleSelection(otherUserId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? colors.accent.withValues(alpha: 0.15)
              : hasUnread
              ? colors.accent.withValues(alpha: 0.07)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: colors.divider, width: 0.8),
            left: isSelected
                ? BorderSide(color: colors.accent, width: 3)
                : BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            // ── Avatar ─────────────────────────────────────────────
            Stack(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: isSelected
                      ? CircleAvatar(
                          key: const ValueKey("check"),
                          radius: 26,
                          backgroundColor: colors.accent,
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 22,
                          ),
                        )
                      : CircleAvatar(
                          key: const ValueKey("initials"),
                          radius: 26,
                          backgroundColor: colors.accent,
                          child: Text(
                            getInitials(name),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                ),
                if (isOnline && !isSelected)
                  Positioned(
                    bottom: 1,
                    right: 1,
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: colors.onlineGreen,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.screenBg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(width: 12),

            // ── Name + last message ──────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            if (isPinned) ...[
                              Icon(
                                Icons.push_pin,
                                size: 13,
                                color: colors.accent,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: hasUnread
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  fontSize: 15,
                                  color: colors.primaryText,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: hasUnread
                              ? colors.accent
                              : colors.secondaryText,
                          fontWeight: hasUnread
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildTickIcon(lastSentStatus, colors),
                      if (lastSentStatus != null) const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          lastMessage,
                          style: TextStyle(
                            color: hasUnread
                                ? colors.primaryText
                                : colors.secondaryText,
                            fontSize: 13,
                            fontWeight: hasUnread
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: colors.accent,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            unreadCount > 99 ? "99+" : unreadCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
