import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../cache/cache_service.dart';
import '../cache/models/chat_room_cache.dart';
import '../cache/models/user_cache.dart';

/// Repository for chat room operations with local-first architecture.
/// 
/// Firestore → Cache → UI
/// UI reads from cache only. Firestore listeners update cache.
class ChatRoomRepository {
  static final _firestore = FirebaseFirestore.instance;
   
  // In-memory streams for reactive UI updates
  // CRITICAL FIX: Changed from 'final' to nullable to allow recreation after dispose
  static StreamController<List<ChatRoomCache>>? _roomsController;
  static final _unreadCountControllers = <String, StreamController<int>>{};
  
  /// Get or create the rooms stream controller
  /// This allows recreation after the controller has been closed
  static StreamController<List<ChatRoomCache>> _getOrCreateController() {
    if (_roomsController == null || _roomsController!.isClosed) {
      _roomsController = StreamController<List<ChatRoomCache>>.broadcast();
      _dbg('Created new rooms controller');
    }
    return _roomsController!;
  }
  
  // Firestore subscriptions
  static StreamSubscription<QuerySnapshot>? _roomsSubscription;
  static final _roomSubscriptions = <String, StreamSubscription<DocumentSnapshot>>{};
  
  // Sync state
  static String? _currentUserId;
  static bool _isSyncing = false;
  
  // Deduplication - track last emitted rooms to prevent duplicate emissions
  static List<ChatRoomCache>? _lastEmittedRooms;
  static DateTime _lastEmissionTime = DateTime(1970);
  
  // Throttling - minimum time between emissions (reduced from 1s to 3s for better performance)
  static const Duration _minEmissionInterval = Duration(seconds: 3);
  
  // Debug logging throttling - don't log the same message too frequently
  static DateTime _lastLogTime = DateTime(1970);
  static String? _lastLogMessage;
  static const Duration _minLogInterval = Duration(seconds: 5);
  
  /// Throttled debug logging - reduces log spam
  static void _dbg(String message) {
    assert(() {
      // Skip duplicate messages within throttle window
      final now = DateTime.now();
      if (_lastLogMessage == message && 
          now.difference(_lastLogTime) < _minLogInterval) {
        return true;
      }
      _lastLogMessage = message;
      _lastLogTime = now;
      debugPrint('[ChatRoomRepository] $message');
      return true;
    }());
  }

  /// Initialize and start syncing for a user
  static Future<void> initialize(String userId) async {
    // GUARD: Prevent duplicate initialization
    if (_currentUserId == userId && _isSyncing) {
      _dbg('initialize: already initialized for $userId');
      return;
    }
    
    // GUARD: Prevent rapid re-initialization
    final timeSinceInit = DateTime.now().difference(_lastEmissionTime);
    if (_isSyncing && timeSinceInit < const Duration(seconds: 2)) {
      _dbg('initialize: throttled (init ${timeSinceInit.inMilliseconds}ms ago)');
      return;
    }
    
    _currentUserId = userId;
    _dbg('initializing for user $userId');
    
    // Start Firestore sync
    _startRoomsSync(userId);
    
    // Emit initial data from cache
    await _emitCachedRooms(userId);
  }

  /// Get stream of chat rooms - reads from local cache, Firestore updates cache
  static Stream<List<ChatRoomCache>> getChatRoomsStream(String userId) {
    _dbg('getting chat rooms stream for user $userId');
    
    // CRITICAL FIX: Ensure controller is valid before returning stream
    final controller = _getOrCreateController();
    
    // Ensure sync is started
    initialize(userId);
    
    return controller.stream;
  }

  /// Get chat rooms once from cache
  static Future<List<ChatRoomCache>> getChatRooms(String userId) async {
    final box = CacheService.chatRoomBox;
    final allRooms = box.values.toList();
    return allRooms
        .where((room) => room.users.contains(userId))
        .toList()
      ..sort((a, b) {
        final aTime = a.lastMessageTime ?? DateTime(1970);
        final bTime = b.lastMessageTime ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
  }

  /// Start Firestore sync for chat rooms
  static void _startRoomsSync(String userId) {
    // GUARD: Prevent duplicate subscriptions
    if (_isSyncing && _roomsSubscription != null) {
      _dbg('rooms sync already active, skipping duplicate subscription');
      return;
    }
    
    _isSyncing = true;
    
    _dbg('starting rooms sync');
    
    // Cancel existing subscription before creating new one
    _roomsSubscription?.cancel();
    
    _roomsSubscription = _firestore
        .collection('chat_rooms')
        .where('users', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) => _onRoomsSnapshot(snapshot, userId),
          onError: (e) => _dbg('rooms sync error: $e'),
          onDone: () {
            _dbg('rooms subscription ended');
            _roomsSubscription = null;
            _isSyncing = false;
          },
        );
  }

  static void _onRoomsSnapshot(QuerySnapshot snapshot, String userId) {
    _dbg('received ${snapshot.docChanges.length} room changes');
    
    // Update cache from Firestore
    for (final change in snapshot.docChanges) {
      final doc = change.doc;
      switch (change.type) {
        case DocumentChangeType.added:
        case DocumentChangeType.modified:
          _syncChatRoomFromFirestore(doc.id);
          _startRoomDetailSync(doc.id, userId);
          break;
        case DocumentChangeType.removed:
          CacheService.clearRoomData(doc.id);
          break;
      }
    }
    
    // Emit to UI
    _emitCachedRooms(userId);
  }

  static void _startRoomDetailSync(String roomId, String userId) {
    if (_roomSubscriptions.containsKey(roomId)) return;
    
    _dbg('starting detail sync for room $roomId');
    
    _roomSubscriptions[roomId] = _firestore
        .collection('chat_rooms')
        .doc(roomId)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            if (snapshot.exists) {
              _syncChatRoomFromFirestore(roomId);
              // NOTE: Removed _emitCachedRooms here to prevent duplicate emissions
              // The main rooms listener handles all emissions - this detail sync
              // only updates the cache silently
            }
          },
          onError: (e) => _dbg('room detail sync error for $roomId: $e'),
        );
  }

  static Future<void> _emitCachedRooms(String userId) async {
    var rooms = await getChatRooms(userId);
    
    // ✅ FIX: Deduplicate by roomId - handles same room appearing under multiple query results
    final seen = <String>{};
    rooms = rooms.where((r) => seen.add(r.roomId)).toList();
    
    // ✅ FIX: Deduplicate - don't emit identical rooms repeatedly
    if (_isDuplicateEmission(rooms)) {
      _dbg('duplicate emission skipped (${rooms.length} rooms unchanged)');
      return;
    }
    
    final controller = _getOrCreateController();
    if (!controller.isClosed) {
      _lastEmittedRooms = rooms;
      _lastEmissionTime = DateTime.now();
      controller.add(rooms);
      _dbg('emitted ${rooms.length} cached rooms');
    }
  }
  
  /// Check if this emission would be identical to the last one
  static bool _isDuplicateEmission(List<ChatRoomCache> rooms) {
    if (_lastEmittedRooms == null) return false;
    if (_lastEmittedRooms!.length != rooms.length) return false;
    
    // Check if any room has different data
    for (int i = 0; i < rooms.length; i++) {
      final last = _lastEmittedRooms![i];
      final current = rooms[i];
      
      if (last.roomId != current.roomId) return false;
      if (last.lastMessage != current.lastMessage) return false;
      if (last.lastMessageTime != current.lastMessageTime) return false;
    }
    
    // Also throttle emissions - don't emit more than once every 3 seconds
    // This reduces unnecessary UI rebuilds while keeping data fresh
    final timeSinceLast = DateTime.now().difference(_lastEmissionTime);
    if (timeSinceLast < _minEmissionInterval) {
      return true;
    }
    
    return true;
  }

  /// Sync a chat room from Firestore to cache
  static Future<void> _syncChatRoomFromFirestore(String roomId) async {
    try {
      final doc = await _firestore.collection('chat_rooms').doc(roomId).get();
      if (!doc.exists) return;

      final data = doc.data()!;
      final users = List<String>.from(data['users'] ?? []);
      final pinnedBy = List<String>.from(data['pinnedBy'] ?? []);
      final mutedBy = <String, bool>{};
      for (final uid in users) {
        mutedBy[uid] = data['muted_$uid'] ?? false;
      }

      final cache = ChatRoomCache()
        ..roomId = roomId
        ..users = users
        ..lastMessage = data['lastMessage'] as String?
        ..lastMessageTime = (data['lastMessageTime'] as Timestamp?)?.toDate()
        ..pinnedByCurrentUser = pinnedBy.isNotEmpty
        ..mutedBy = mutedBy
        ..cachedAt = DateTime.now()
        ..syncedAt = DateTime.now();

      await CacheService.chatRoomBox.put(roomId, cache);
      _dbg('synced chat room $roomId to cache');
    } catch (e) {
      _dbg('sync chat room $roomId failed: $e');
    }
  }

  /// Get unread count stream for a specific room
  static Stream<int> getUnreadCountStream(String roomId, String userId, DateTime? lastSeen) {
    if (!_unreadCountControllers.containsKey(roomId)) {
      _unreadCountControllers[roomId] = StreamController<int>.broadcast(
        onCancel: () {
          _unreadCountControllers[roomId]?.close();
          _unreadCountControllers.remove(roomId);
        },
      );
    }
    
    // Initial calculation from cache
    _calculateAndEmitUnread(roomId, userId, lastSeen);
    
    return _unreadCountControllers[roomId]!.stream;
  }

  static Future<void> _calculateAndEmitUnread(String roomId, String userId, DateTime? lastSeen) async {
    // Count from cached messages using direct box access
    final box = CacheService.messageBox;
    final messages = box.values.where((m) => m.roomId == roomId).toList();
    final count = messages.where((m) {
      if (m.senderId == userId) return false;
      if (lastSeen == null) return true;
      if (m.timestamp == null) return false;
      return m.timestamp!.isAfter(lastSeen);
    }).length;
    
    if (_unreadCountControllers.containsKey(roomId) && !_unreadCountControllers[roomId]!.isClosed) {
      _unreadCountControllers[roomId]!.add(count);
    }
  }

  /// Pin/unpin a chat room
  static Future<void> pinChatRoom(String roomId, String userId, bool pin) async {
    await _firestore.collection('chat_rooms').doc(roomId).update({
      'pinnedBy': pin ? FieldValue.arrayUnion([userId]) : FieldValue.arrayRemove([userId]),
    });
    // Cache will update via sync listener
  }

  /// Mute/unmute a chat room
  static Future<void> muteChatRoom(String roomId, String userId, bool mute) async {
    await _firestore.collection('chat_rooms').doc(roomId).update({
      'muted_$userId': mute,
    });
    // Cache will update via sync listener
  }

  /// Delete a chat room
  static Future<void> deleteChatRoom(String roomId) async {
    await _firestore.collection('chat_rooms').doc(roomId).delete();
    await CacheService.clearRoomData(roomId);
  }

  /// Get other user info for a chat room
  static Future<UserCache?> getOtherUser(String roomId, String currentUserId) async {
    final room = CacheService.chatRoomBox.get(roomId);
    if (room == null) return null;
    
    final otherUserId = room.users.firstWhere(
      (uid) => uid != currentUserId,
      orElse: () => '',
    );
    
    if (otherUserId.isEmpty) return null;
    
    return CacheService.userBox.get('user_$otherUserId');
  }

  /// Get a chat room from cache
  static Future<ChatRoomCache?> getChatRoom(String roomId) async {
    return CacheService.chatRoomBox.get(roomId);
  }

  /// Search chat rooms from cache
  static Future<List<ChatRoomCache>> searchChatRooms(String userId, String query) async {
    final rooms = await getChatRooms(userId);
    if (query.isEmpty) return rooms;
    
    final lowerQuery = query.toLowerCase();
    return rooms.where((room) {
      // Search by room data
      final matchesRoom = room.lastMessage?.toLowerCase().contains(lowerQuery) ?? false;
      return matchesRoom;
    }).toList();
  }

  /// Refresh rooms from Firestore
  static Future<void> refresh(String userId) async {
    _dbg('manual refresh requested');
    
    // Force a re-sync
    _isSyncing = false;
    _startRoomsSync(userId);
    
    // Also fetch fresh data
    try {
      final snapshot = await _firestore
          .collection('chat_rooms')
          .where('users', arrayContains: userId)
          .orderBy('lastMessageTime', descending: true)
          .get();
      
      for (final doc in snapshot.docs) {
        await _syncChatRoomFromFirestore(doc.id);
      }
      
      await _emitCachedRooms(userId);
    } catch (e) {
      _dbg('refresh failed: $e');
    }
  }

  /// Dispose all resources
  static Future<void> dispose() async {
    _dbg('disposing repository');
    
    await _roomsSubscription?.cancel();
    _roomsSubscription = null;
    
    for (final sub in _roomSubscriptions.values) {
      await sub.cancel();
    }
    _roomSubscriptions.clear();
    
    for (final controller in _unreadCountControllers.values) {
      await controller.close();
    }
    _unreadCountControllers.clear();
    
    // CRITICAL FIX: Check if controller exists before closing
    if (_roomsController != null && !_roomsController!.isClosed) {
      await _roomsController!.close();
    }
    
    _currentUserId = null;
    _isSyncing = false;
  }

  /// Clear cache for specific user
  static Future<void> clearUserData(String userId) async {
    await CacheService.clearUserData(userId);
  }
}
