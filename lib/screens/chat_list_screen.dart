import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import '../services/auth_service.dart';
import '../services/chat_util_service.dart';
import '../services/chat_list_service.dart';
import '../services/encryption_startup_service.dart' as enc;
import '../utils/avatar_utils.dart';
import '../main.dart';
import '../repositories/chat_room_repository.dart';
import '../cache/models/chat_room_cache.dart';
import '../services/startup_task_scheduler.dart';
import 'chat_screen_wrapper.dart';
import 'user_list_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'linked_devices_screen.dart';

/// Model for user profile data to ensure proper hydration
class _UserProfile {
  final String name;
  final bool isOnline;
  final DateTime? lastSeen;
  
  const _UserProfile({
    required this.name,
    this.isOnline = false,
    this.lastSeen,
  });
}

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with WidgetsBindingObserver {
  final currentUser = FirebaseAuth.instance.currentUser!;

  String searchQuery = '';

  // CACHE-FIRST: Use repository stream instead of direct Firestore
  Stream<List<ChatRoomCache>>? _chatRoomsStream;

  // Cached chat data for AppBar (eliminates separate StreamBuilder)
  List<ChatRoomCache> _cachedAllChatsData = [];

  // Made static so OptimizedChatTile can access it
  static final Map<String, _UserProfile> _userProfileCache = {};
  final Map<String, int> _unreadCountCache = {};
  final Set<String> _loadedUserIds = {};
  final Set<String> _loadingUserIds = {}; // Track in-flight requests to prevent duplicates

  final Set<String> _selectedChats = {};

  bool get _isSelecting => _selectedChats.isNotEmpty;

  DateTime? _lastDeliveredMarkTime;

  // Encryption startup state (non-blocking banner)
  enc.EncryptionStartupState _encryptionState = enc.EncryptionStartupService.currentState;
  StreamSubscription<enc.EncryptionStateEvent>? _encryptionSubscription;

  // Device trust pending approval listener
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _pendingDevicesSubscription;
  bool _isDeviceApprovalBannerShown = false;

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
    // CACHE-FIRST: Initialize repository and get cache-backed stream
    ChatRoomRepository.initialize(currentUser.uid);
    _chatRoomsStream = ChatRoomRepository.getChatRoomsStream(currentUser.uid);
    
    // DEFER: Mark all messages delivered using startup scheduler
    // This prevents frame drops during initial render
    // Runs as LOW priority - 2 seconds after first frame
    StartupTaskScheduler.register(
      name: 'chat_mark_delivered',
      priority: StartupTaskPriority.low,
      task: () async {
        if (mounted) await _markAllDeliveredDebounced();
      },
    );

    // Listen to encryption startup state for non-blocking banner
    _encryptionSubscription = enc.EncryptionStartupService.stateStream.listen((event) {
      if (mounted) {
        setState(() {
          _encryptionState = event.state;
        });
      }
    });

    // Listen for pending device approvals
    _listenForPendingDeviceApprovals();
  }

  /// Listen for devices waiting for trust approval
  void _listenForPendingDeviceApprovals() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _dbg('No current user, skipping device approval listener');
      return;
    }

    _dbg('Starting device approval listener for user: ${user.uid}');
    
    _pendingDevicesSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('devices')
        .where('trusted', isEqualTo: false)
        .where('revoked', isEqualTo: false)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted) return;
        
        final pendingCount = snapshot.docs.length;
        _dbg('Device approval snapshot: $pendingCount pending devices');
        
        if (pendingCount > 0) {
          // Check if any are new (for notification)
          final newDevices = snapshot.docs.where((doc) {
            final data = doc.data();
            final requestedAt = data['trustRequestedAt'] as Timestamp?;
            if (requestedAt == null) return false;
            // Consider new if requested in last 30 seconds
            return DateTime.now().difference(requestedAt.toDate()).inSeconds < 30;
          }).toList();
          
          if (newDevices.isNotEmpty) {
            _dbg('New device(s) awaiting approval: ${newDevices.length}');
            
            // Send OneSignal notification to trusted devices
            _sendDeviceApprovalNotification(newDevices.length);
          }
          
          if (!_isDeviceApprovalBannerShown) {
            _showDeviceApprovalBanner();
          }
        } else {
          if (_isDeviceApprovalBannerShown) {
            _hideDeviceApprovalBanner();
          }
        }
      },
      onError: (e) {
        _dbg('Device approval listener error: $e');
      },
    );
  }

  /// Show MaterialBanner for device approval
  void _showDeviceApprovalBanner() {
    _isDeviceApprovalBannerShown = true;
    _dbg('Showing device approval banner');
    
    if (mounted) {
      ScaffoldMessenger.of(context).showMaterialBanner(
        MaterialBanner(
          content: const Text(
            'A new device is waiting for approval. Tap to review.',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.orange.shade800,
          leading: const Icon(Icons.devices, color: Colors.white),
          actions: [
            TextButton(
              onPressed: () {
                if (!mounted) return;
                _hideDeviceApprovalBanner();
                if (mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const LinkedDevicesScreen(),
                    ),
                  );
                }
              },
              child: const Text(
                'REVIEW',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: () {
                if (!mounted) return;
                _hideDeviceApprovalBanner();
              },
              child: const Text(
                'DISMISS',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    }
  }

  /// Hide device approval banner
  void _hideDeviceApprovalBanner() {
    _isDeviceApprovalBannerShown = false;
    _dbg('Hiding device approval banner');
    
    // Only hide banner if widget is still mounted and context is valid
    if (mounted && context.mounted) {
      try {
        ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
      } catch (e) {
        // Ignore if scaffold messenger is not available (during dispose)
        _dbg('Could not hide banner: $e');
      }
    }
  }

  /// Send OneSignal notification for new device approval request
  /// This notifies all trusted devices of the current user
  void _sendDeviceApprovalNotification(int deviceCount) {
    _dbg('Sending device approval notification for $deviceCount device(s)');
    
    try {
      // Get current user
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _dbg('No current user, skipping notification');
        return;
      }
      
      // Request notification permission if not granted
      OneSignal.Notifications.requestPermission(false).then((granted) {
        if (granted) {
          _dbg('Notification permission granted');
        } else {
          _dbg('Notification permission not granted');
        }
      });
      
      // Log device approval notification
      // Note: OneSignal postNotification requires server-side implementation
      // The notification permission request above ensures user can receive
      // notifications sent from backend when new devices need approval
      _dbg('Device approval notification prepared for $deviceCount device(s)');
      _dbg('Note: Backend push notification would be sent here');
    } catch (e) {
      _dbg('Failed to send device approval notification: $e');
      // Non-fatal: notification failure shouldn't break the app
    }
  }

  @override
  void dispose() {
    _encryptionSubscription?.cancel();
    _pendingDevicesSubscription?.cancel();
    // Don't call _hideDeviceApprovalBanner() here - context is no longer valid
    // The banner will be automatically removed when the screen is disposed
    // 
    // CRITICAL FIX: Don't dispose repository here - it should be app-scoped
    // Disposing it causes the stream controller to close, leading to empty chat list
    // Repository is now disposed only on logout in main.dart
    // ChatRoomRepository.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _preloadChatData(List<DocumentSnapshot> docs) async {
    final userIdsToLoad = <String>{};

    for (final doc in docs) {
      final chatData = doc.data() as Map<String, dynamic>;
      final users = List<String>.from(chatData['users'] ?? []);
      for (final userId in users) {
        if (userId != currentUser.uid && 
            !_loadedUserIds.contains(userId) &&
            !_loadingUserIds.contains(userId)) {
          userIdsToLoad.add(userId);
        }
      }
    }

    if (userIdsToLoad.isEmpty) return;

    // Mark all as loading immediately to prevent duplicate requests
    _loadingUserIds.addAll(userIdsToLoad);

    for (final userId in userIdsToLoad) {
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .get();

        if (userDoc.exists && userDoc.data() != null) {
          final data = userDoc.data()!;
          final name = data['name'] as String? ?? 'User';
          final isOnlineField = data['isOnline'] as bool? ?? false;
          final lastSeenTs = data['lastSeen'] as Timestamp?;
          
          // Calculate online status with 20-second window
          bool isOnline = false;
          DateTime? lastSeen;
          if (lastSeenTs != null) {
            lastSeen = lastSeenTs.toDate();
            if (isOnlineField && DateTime.now().difference(lastSeen).inSeconds < 20) {
              isOnline = true;
            }
          }
          
          _userProfileCache[userId] = _UserProfile(
            name: name,
            isOnline: isOnline,
            lastSeen: lastSeen,
          );
          _loadedUserIds.add(userId);
          _dbg('preloaded user profile for $userId: $name');
        } else {
          // User doc doesn't exist - cache a default profile
          _userProfileCache[userId] = const _UserProfile(name: 'Unknown User');
          _loadedUserIds.add(userId);
          _dbg('user $userId not found, using default profile');
        }
      } catch (e) {
        _dbg('failed to preload user $userId: ${e.runtimeType}');
        // Cache error state to prevent repeated failed requests
        _userProfileCache[userId] = const _UserProfile(name: 'User');
        _loadedUserIds.add(userId);
      } finally {
        _loadingUserIds.remove(userId);
      }
    }
    
    // Trigger rebuild if we loaded new data
    if (mounted && userIdsToLoad.isNotEmpty) {
      setState(() {});
    }
  }
  
  /// Ensures user profile is loaded before returning
  /// Returns cached profile or triggers a fetch
  _UserProfile _getUserProfile(String userId) {
    // Return cached profile if available
    if (_userProfileCache.containsKey(userId)) {
      return _userProfileCache[userId]!;
    }
    
    // Trigger background fetch if not already loading
    if (!_loadingUserIds.contains(userId) && !_loadedUserIds.contains(userId)) {
      _fetchUserProfileAsync(userId);
    }
    
    // Return placeholder while loading
    return const _UserProfile(name: 'Loading...');
  }
  
  Future<void> _fetchUserProfileAsync(String userId) async {
    if (_loadingUserIds.contains(userId)) return;
    
    _loadingUserIds.add(userId);
    
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      
      if (mounted) {
        if (userDoc.exists && userDoc.data() != null) {
          final data = userDoc.data()!;
          final name = data['name'] as String? ?? 'User';
          final isOnlineField = data['isOnline'] as bool? ?? false;
          final lastSeenTs = data['lastSeen'] as Timestamp?;
          
          bool isOnline = false;
          DateTime? lastSeen;
          if (lastSeenTs != null) {
            lastSeen = lastSeenTs.toDate();
            if (isOnlineField && DateTime.now().difference(lastSeen).inSeconds < 20) {
              isOnline = true;
            }
          }
          
          _userProfileCache[userId] = _UserProfile(
            name: name,
            isOnline: isOnline,
            lastSeen: lastSeen,
          );
        } else {
          _userProfileCache[userId] = const _UserProfile(name: 'Unknown User');
        }
        _loadedUserIds.add(userId);
        setState(() {});
      }
    } catch (e) {
      _dbg('failed to fetch user $userId: $e');
      if (mounted) {
        _userProfileCache[userId] = const _UserProfile(name: 'User');
        _loadedUserIds.add(userId);
        setState(() {});
      }
    } finally {
      _loadingUserIds.remove(userId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _markAllDeliveredDebounced();
      
      // CRITICAL FIX: Check and restore stream if needed after app resume
      // This fixes the issue where system navigation or backgrounding causes empty chat list
      _checkAndRestoreStream();
    }
  }
  
  /// Check if the repository stream is still active and restore if needed
  /// This fixes the issue where system navigation causes the stream to die
  void _checkAndRestoreStream() async {
    try {
      _dbg('Checking stream health after resume...');
      
      // Get a fresh stream from the repository
      final newStream = ChatRoomRepository.getChatRoomsStream(currentUser.uid);
      
      // Check if the stream reference has changed or if we need to update
      if (newStream != _chatRoomsStream) {
        _dbg('Stream restored after lifecycle change');
        if (mounted) {
          setState(() {
            _chatRoomsStream = newStream;
          });
        }
      }
    } catch (e) {
      _dbg('Failed to restore stream: $e');
      // Try to reinitialize repository if needed
      try {
        await ChatRoomRepository.initialize(currentUser.uid);
        if (mounted) {
          setState(() {
            _chatRoomsStream = ChatRoomRepository.getChatRoomsStream(currentUser.uid);
          });
        }
      } catch (e2) {
        _dbg('Failed to reinitialize repository: $e2');
      }
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
          .collection('chat_rooms')
          .where('users', arrayContains: currentUser.uid)
          .get();

      if (rooms.docs.isEmpty) return;

      final receiverIds = <String>[];
      for (final room in rooms.docs) {
        final roomData = room.data();
        final users = List<String>.from(roomData['users'] ?? []);
        final otherUserId = users.firstWhere(
          (id) => id != currentUser.uid,
          orElse: () => '',
        );
        if (otherUserId.isNotEmpty) {
          receiverIds.add(otherUserId);
        }
      }

      if (receiverIds.isNotEmpty) {
        await ChatUtilService.markAllMessagesDeliveredBatched(
          currentUser.uid,
          receiverIds,
        );
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
        .collection('chat_rooms')
        .doc(roomId);

    final roomSnap = await roomRef.get();
    if (!roomSnap.exists) {
      _dbg('deleteChatRoom: room not found — already deleted');
      return;
    }

    final roomData = roomSnap.data();
    final users = List<String>.from(roomData?['users'] ?? []);

    if (!users.contains(currentUser.uid)) {
      throw Exception('Not a participant of this chat');
    }

    _dbg('deleteChatRoom: deleting messages subcollection');
    await _deleteSubcollection(roomRef.collection('messages'));

    _dbg('deleteChatRoom: deleting game subcollection');
    await _deleteSubcollection(roomRef.collection('game'));

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
          'This will permanently delete the selected '
          "conversation${count > 1 ? 's' : ''} and all messages. "
          'This cannot be undone.',
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
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

  // ── Helper for AppBar pin state ────────────────────────────────────────
  bool _areAllSelectedPinned(List<ChatRoomCache> allChatsData) {
    if (_selectedChats.isEmpty) return false;
    return _selectedChats.every((otherUserId) {
      final room = allChatsData.firstWhere(
        (r) => r.users.contains(otherUserId) && r.users.contains(currentUser.uid),
        orElse: () => ChatRoomCache()..roomId = ''..users = [],
      );
      return room.isPinned;
    });
  }

  // ── Pin / Unpin selected chats ─────────────────────────────────────────

  Future<void> _pinSelectedChats(
    List<ChatRoomCache> allChatsData,
  ) async {
    final allPinned =
        _selectedChats.isNotEmpty &&
        _selectedChats.every((otherUserId) {
          final room = allChatsData.firstWhere(
            (r) => r.users.contains(otherUserId) && r.users.contains(currentUser.uid),
            orElse: () => ChatRoomCache()..roomId = ''..users = [],
          );
          return room.isPinned;
        });

    final toProcess = Set<String>.from(_selectedChats);
    _clearSelection();

    int failed = 0;
    for (final otherUserId in toProcess) {
      final roomId = getRoomId(currentUser.uid, otherUserId);
      final roomRef = FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(roomId);
      try {
        await roomRef.update({
          'pinnedBy': allPinned
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
        allPinned ? 'Unpinned' : 'Pinned',
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
        title: Text('Log Out', style: TextStyle(color: colors.primaryText)),
        content: Text(
          'Are you sure you want to log out?',
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log Out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _dbg('logout confirmed');
      await AuthService.logout(context);
    }
  }

  // ── Encryption Banner (Non-blocking) ─────────────────────────────────

  Widget _buildEncryptionBanner(dynamic colors) {
    // Only show banner when actively syncing or starting
    if (_encryptionState != enc.EncryptionStartupState.starting &&
        _encryptionState != enc.EncryptionStartupState.checkingLocalKeys &&
        _encryptionState != enc.EncryptionStartupState.restoringFromBackup &&
        _encryptionState != enc.EncryptionStartupState.generatingKeys &&
        _encryptionState != enc.EncryptionStartupState.syncingToFirestore) {
      return const SizedBox.shrink();
    }

    final message = switch (_encryptionState) {
      enc.EncryptionStartupState.starting => 'Securing chats...',
      enc.EncryptionStartupState.checkingLocalKeys => 'Checking keys...',
      enc.EncryptionStartupState.restoringFromBackup => 'Restoring your keys...',
      enc.EncryptionStartupState.generatingKeys => 'Generating secure keys...',
      enc.EncryptionStartupState.syncingToFirestore => 'Syncing keys...',
      _ => 'Securing...',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.blue.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.blue.shade700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            message,
            style: TextStyle(
              color: Colors.blue.shade700,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
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
            ? _buildSelectionAppBar(colors, allChatsData: _cachedAllChatsData)
            : _buildNormalAppBar(colors, allChatsData: _cachedAllChatsData),
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
                      hintText: 'Search chats...',
                      hintStyle: TextStyle(color: colors.hintText),
                      border: InputBorder.none,
                    ),
                    onChanged: (value) =>
                        setState(() => searchQuery = value.toLowerCase()),
                  ),
                ),
              ),

            // Non-blocking encryption startup banner
            _buildEncryptionBanner(colors),

            Expanded(
              // CACHE-FIRST: StreamBuilder uses ChatRoomRepository (Cache → UI)
              child: StreamBuilder<List<ChatRoomCache>>(
                stream: _chatRoomsStream,
                builder: (context, snapshot) {
                  // CACHE-FIRST: Show cached data immediately if available
                  final rooms = snapshot.data ?? _cachedAllChatsData;
                  _cachedAllChatsData = rooms;

                  // Show loading only briefly, then show empty state or offline message
                  if (rooms.isEmpty && !snapshot.hasData && snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(color: colors.accent),
                    );
                  }

                  // Handle error state (e.g., offline)
                  if (rooms.isEmpty && snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            size: 64,
                            color: colors.hintText,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Unable to connect',
                            style: TextStyle(
                              fontSize: 16,
                              color: colors.secondaryText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Check your internet connection',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.hintText,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  if (rooms.isEmpty) {
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
                            'No chats yet',
                            style: TextStyle(
                              fontSize: 16,
                              color: colors.secondaryText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap the edit icon to start a conversation',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.hintText,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  _dbg('CACHE-FIRST: Rendering ${rooms.length} chat rooms from cache');

                  // ── Sort: pinned first, then by lastMessageTime ──────
                  final sortedRooms = [...rooms];
                  sortedRooms.sort((a, b) {
                    final aPinned = a.isPinned;
                    final bPinned = b.isPinned;

                    if (aPinned && !bPinned) return -1;
                    if (!aPinned && bPinned) return 1;

                    final aTime = a.lastMessageTime?.millisecondsSinceEpoch ?? 0;
                    final bTime = b.lastMessageTime?.millisecondsSinceEpoch ?? 0;
                    return bTime.compareTo(aTime);
                  });

                  // OPTIMIZED: Use OptimizedChatTile with ValueKey for stable identity
                  // and RepaintBoundary for paint isolation
                  return ListView.builder(
                    // Performance optimizations
                    addAutomaticKeepAlives: true,
                    addRepaintBoundaries: true,
                    cacheExtent: 200.0, // Preload items 200px off-screen
                    
                    itemCount: sortedRooms.length,
                    itemBuilder: (context, index) {
                      final room = sortedRooms[index];
                      final users = room.users;
                      final otherUserId = users.firstWhere(
                        (id) => id != currentUser.uid,
                        orElse: () => '',
                      );
                      if (otherUserId.isEmpty) return const SizedBox.shrink();
                      
                      // Filter by search query early
                      if (searchQuery.isNotEmpty) {
                        final profile = _userProfileCache[otherUserId];
                        final name = profile?.name ?? 'User';
                        if (!name.toLowerCase().contains(searchQuery)) {
                          return const SizedBox.shrink();
                        }
                      }

                      return OptimizedChatTile(
                        key: ValueKey(room.roomId), // Stable identity
                        roomId: room.roomId,
                        otherUserId: otherUserId,
                        room: room,
                        isSelected: _selectedChats.contains(room.roomId),
                        onTap: () {
                          if (_isSelecting) {
                            _toggleSelection(otherUserId);
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreenWrapper(receiverId: otherUserId),
                              ),
                            );
                          }
                        },
                        onLongPress: () => _toggleSelection(otherUserId),
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

  PreferredSizeWidget _buildNormalAppBar(AppColors colors, {List<ChatRoomCache>? allChatsData}) {
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
            'Chats',
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
        if (allChatsData != null && _selectedChats.isNotEmpty)
          IconButton(
            icon: Icon(
              _areAllSelectedPinned(allChatsData) ? Icons.push_pin : Icons.push_pin_outlined,
              color: _areAllSelectedPinned(allChatsData) ? colors.accent : colors.primaryText,
            ),
            tooltip: _areAllSelectedPinned(allChatsData) ? 'Unpin' : 'Pin',
            onPressed: () => _pinSelectedChats(allChatsData),
          ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: colors.primaryText),
          color: colors.cardBg,
          onSelected: (value) async {
            switch (value) {
              case 'profile':
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              case 'settings':
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              case 'logout':
                await _handleLogout();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'profile',
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 18,
                    color: colors.secondaryText,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'My Profile',
                    style: TextStyle(color: colors.primaryText),
                  ),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'settings',
              child: Row(
                children: [
                  Icon(
                    Icons.settings_outlined,
                    size: 18,
                    color: colors.secondaryText,
                  ),
                  const SizedBox(width: 10),
                  Text('Settings', style: TextStyle(color: colors.primaryText)),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'logout',
              child: Row(
                children: [
                  Icon(Icons.logout, size: 18, color: Colors.red),
                  SizedBox(width: 10),
                  Text('Log Out', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar(AppColors colors, {List<ChatRoomCache>? allChatsData}) {
    return AppBar(
      backgroundColor: colors.appBarBg,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.close, color: colors.primaryText),
        onPressed: _clearSelection,
      ),
      title: Text(
        '${_selectedChats.length} selected',
        style: TextStyle(
          color: colors.primaryText,
          fontWeight: FontWeight.w600,
          fontSize: 18,
        ),
      ),
      actions: [
        if (allChatsData != null)
          IconButton(
            icon: Icon(
              _areAllSelectedPinned(allChatsData) ? Icons.push_pin : Icons.push_pin_outlined,
              color: _areAllSelectedPinned(allChatsData) ? colors.accent : colors.primaryText,
            ),
            tooltip: _areAllSelectedPinned(allChatsData) ? 'Unpin' : 'Pin',
            onPressed: () => _pinSelectedChats(allChatsData),
          )
        else
          IconButton(
            icon: Icon(Icons.push_pin_outlined, color: colors.primaryText),
            onPressed: null,
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          tooltip: 'Delete',
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
              builder: (_) => ChatScreenWrapper(receiverId: otherUserId),
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
                          key: const ValueKey('check'),
                          radius: 26,
                          backgroundColor: colors.accent,
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 22,
                          ),
                        )
                      : CircleAvatar(
                          key: const ValueKey('initials'),
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
                            unreadCount > 99 ? '99+' : unreadCount.toString(),
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

// ============================================================================
// OPTIMIZED CHAT TILE WIDGET
// ============================================================================

/// Optimized chat tile with:
/// - const constructor where possible
/// - RepaintBoundary for paint isolation
/// - AutomaticKeepAlive for smooth scrolling
/// - ValueKey for stable identity
/// - Selective rebuilds via ValueNotifier pattern
class OptimizedChatTile extends StatefulWidget {
  final String roomId;
  final String otherUserId;
  final ChatRoomCache room;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const OptimizedChatTile({
    super.key,
    required this.roomId,
    required this.otherUserId,
    required this.room,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<OptimizedChatTile> createState() => _OptimizedChatTileState();
}

class _OptimizedChatTileState extends State<OptimizedChatTile>
    with AutomaticKeepAliveClientMixin {
  
  // Keep alive during scrolling for smoother experience
  @override
  bool get wantKeepAlive => true;

  late final ValueNotifier<int> _unreadCountNotifier;
  late final ValueNotifier<_UserProfile?> _userProfileNotifier;
  Timer? _unreadRefreshTimer;

  @override
  void initState() {
    super.initState();
    _unreadCountNotifier = ValueNotifier<int>(0);
    _userProfileNotifier = ValueNotifier<_UserProfile?>(null);
    
    // Initial load
    _loadUnreadCount();
    _loadUserProfile();
    
    // Set up periodic refresh for unread count (every 30 seconds)
    _unreadRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadUnreadCount(),
    );
  }

  @override
  void didUpdateWidget(covariant OptimizedChatTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Only reload if room data changed significantly
    if (oldWidget.room.lastMessageTime != widget.room.lastMessageTime ||
        oldWidget.room.lastMessage != widget.room.lastMessage) {
      _loadUnreadCount();
    }
    
    // Only reload user profile if different user
    if (oldWidget.otherUserId != widget.otherUserId) {
      _loadUserProfile();
    }
  }

  @override
  void dispose() {
    _unreadRefreshTimer?.cancel();
    _unreadCountNotifier.dispose();
    _userProfileNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadUnreadCount() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;
      
      final snapshot = await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.roomId)
          .collection('messages')
          .where('receiverId', isEqualTo: currentUser.uid)
          .where('status', whereIn: ['sent', 'delivered'])
          .count()
          .get();
      
      _unreadCountNotifier.value = snapshot.count ?? 0;
    } catch (e) {
      // Silently ignore - non-critical
    }
  }

  Future<void> _loadUserProfile() async {
    try {
      final cached = _ChatListScreenState._userProfileCache[widget.otherUserId];
      if (cached != null) {
        _userProfileNotifier.value = cached;
        return;
      }
      
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.otherUserId)
          .get();
      
      if (userDoc.exists && userDoc.data() != null) {
        final data = userDoc.data()!;
        final name = data['name'] as String? ?? 'User';
        final isOnlineField = data['isOnline'] as bool? ?? false;
        final lastSeenTs = data['lastSeen'] as Timestamp?;
        
        bool isOnline = false;
        DateTime? lastSeen;
        if (lastSeenTs != null) {
          lastSeen = lastSeenTs.toDate();
          if (isOnlineField && DateTime.now().difference(lastSeen).inSeconds < 20) {
            isOnline = true;
          }
        }
        
        final profile = _UserProfile(
          name: name,
          isOnline: isOnline,
          lastSeen: lastSeen,
        );
        
        _userProfileNotifier.value = profile;
        _ChatListScreenState._userProfileCache[widget.otherUserId] = profile;
      }
    } catch (e) {
      // Use default profile on error
      _userProfileNotifier.value = const _UserProfile(name: 'User');
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final isToday = time.day == now.day && 
                    time.month == now.month && 
                    time.year == now.year;
    if (isToday) {
      return "${time.hour.toString().padLeft(2, '0')}:"
              "${time.minute.toString().padLeft(2, '0')}";
    } else {
      return '${time.day}/${time.month}/${time.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    
    final colors = AppColors.of(context);
    final room = widget.room;
    final isPinned = room.isPinned;
    
    return RepaintBoundary(
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? colors.accent.withOpacity(0.15)
                : _unreadCountNotifier.value > 0
                    ? colors.accent.withOpacity(0.07)
                    : Colors.transparent,
            border: Border(
              bottom: BorderSide(color: colors.divider, width: 0.8),
              left: widget.isSelected
                  ? BorderSide(color: colors.accent, width: 3)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            children: [
              // Avatar with online indicator
              _buildAvatar(colors),
              const SizedBox(width: 12),
              
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(colors, isPinned),
                    const SizedBox(height: 4),
                    _buildMessagePreview(colors),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(AppColors colors) {
    return ValueListenableBuilder<_UserProfile?>(
      valueListenable: _userProfileNotifier,
      builder: (context, profile, _) {
        final name = profile?.name ?? 'User';
        final isOnline = profile?.isOnline ?? false;
        
        return Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: widget.isSelected
                  ? CircleAvatar(
                      key: const ValueKey('check'),
                      radius: 26,
                      backgroundColor: colors.accent,
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 22,
                      ),
                    )
                  : CircleAvatar(
                      key: ValueKey('avatar_$name'),
                      radius: 26,
                      backgroundColor: colors.accent,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
            ),
            if (isOnline && !widget.isSelected)
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
        );
      },
    );
  }

  Widget _buildHeader(AppColors colors, bool isPinned) {
    return ValueListenableBuilder<_UserProfile?>(
      valueListenable: _userProfileNotifier,
      builder: (context, profile, _) {
        final name = profile?.name ?? 'User';
        final hasUnread = _unreadCountNotifier.value > 0;
        
        return Row(
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
              _formatTime(widget.room.lastMessageTime),
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
        );
      },
    );
  }

  Widget _buildMessagePreview(AppColors colors) {
    return ValueListenableBuilder<int>(
      valueListenable: _unreadCountNotifier,
      builder: (context, unreadCount, _) {
        final hasUnread = unreadCount > 0;
        
        return Row(
          children: [
            Expanded(
              child: Text(
                widget.room.lastMessage ?? 'Encrypted message',
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
                  unreadCount > 99 ? '99+' : unreadCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
