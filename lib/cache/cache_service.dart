import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'models/user_cache.dart';
import 'models/chat_room_cache.dart';
import 'models/message_cache.dart';
import 'models/game_cache.dart';
import 'models/typing_cache.dart';

/// Hive cache service with proper initialization guards.
/// 
/// CRITICAL: Must be initialized before any repository access.
/// Call initialize() in main.dart before runApp().
class CacheService {
  static const String _userBoxName = 'users';
  static const String _chatRoomBoxName = 'chat_rooms';
  static const String _messageBoxName = 'messages';
  static const String _gameBoxName = 'games';
  static const String _typingBoxName = 'typing';

  static bool _initialized = false;
  static bool _initializing = false;

  /// Initialize Hive and open all boxes.
  /// 
  /// SAFE: Can be called multiple times, only runs once.
  /// CRITICAL: Must complete before accessing any box.
  static Future<void> initialize() async {
    if (_initialized) {
      _dbg('[CACHE] Already initialized, skipping');
      return;
    }
    
    // GUARD: Prevent duplicate initialization
    if (_initializing) {
      _dbg('[CACHE] Initialization in progress, waiting...');
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      return;
    }
    
    _initializing = true;
    _dbg('[CACHE] Starting Hive initialization...');

    try {
      await Hive.initFlutter();
      _dbg('[CACHE] Hive.initFlutter() complete');

      // Register adapters
      Hive.registerAdapter(UserCacheAdapter());
      Hive.registerAdapter(ChatRoomCacheAdapter());
      Hive.registerAdapter(MessageCacheAdapter());
      Hive.registerAdapter(GameCacheAdapter());
      Hive.registerAdapter(TypingStatusCacheAdapter());
      _dbg('[CACHE] Adapters registered');

      // Open all boxes - CRITICAL: must complete before app starts
      await Hive.openBox<UserCache>(_userBoxName);
      _dbg('[CACHE] Opened box: $_userBoxName');
      
      await Hive.openBox<ChatRoomCache>(_chatRoomBoxName);
      _dbg('[CACHE] Opened box: $_chatRoomBoxName');
      
      await Hive.openBox<MessageCache>(_messageBoxName);
      _dbg('[CACHE] Opened box: $_messageBoxName');
      
      await Hive.openBox<GameCache>(_gameBoxName);
      _dbg('[CACHE] Opened box: $_gameBoxName');
      
      await Hive.openBox<TypingStatusCache>(_typingBoxName);
      _dbg('[CACHE] Opened box: $_typingBoxName');

      _initialized = true;
      _dbg('[CACHE] Hive cache initialized successfully');
    } catch (e, st) {
      _dbg('[CACHE] CRITICAL: Hive initialization failed: $e');
      if (kDebugMode) debugPrintStack(stackTrace: st);
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  static void _dbg(String message) {
    assert(() {
      debugPrint(message);
      return true;
    }());
  }

  /// Get user box - GUARD: throws if not initialized
  static Box<UserCache> get userBox {
    _guardInitialized();
    return Hive.box<UserCache>(_userBoxName);
  }
  
  /// Get chat room box - GUARD: throws if not initialized
  static Box<ChatRoomCache> get chatRoomBox {
    _guardInitialized();
    return Hive.box<ChatRoomCache>(_chatRoomBoxName);
  }
  
  /// Get message box - GUARD: throws if not initialized
  static Box<MessageCache> get messageBox {
    _guardInitialized();
    return Hive.box<MessageCache>(_messageBoxName);
  }
  
  /// Get game box - GUARD: throws if not initialized
  static Box<GameCache> get gameBox {
    _guardInitialized();
    return Hive.box<GameCache>(_gameBoxName);
  }
  
  /// Get typing box - GUARD: throws if not initialized
  static Box<TypingStatusCache> get typingBox {
    _guardInitialized();
    return Hive.box<TypingStatusCache>(_typingBoxName);
  }
  
  /// Guard to prevent accessing boxes before initialization
  static void _guardInitialized() {
    if (!_initialized) {
      throw HiveError(
        '[CACHE] CRITICAL: CacheService not initialized! '
        'Call CacheService.initialize() before runApp(). '
        'Box accessed before openBox() was called.'
      );
    }
  }

  static bool get isReady => _initialized;

  static Future<void> close() async {
    await Hive.close();
    _initialized = false;
  }

  static Future<void> clearAll() async {
    await userBox.clear();
    await chatRoomBox.clear();
    await messageBox.clear();
    await gameBox.clear();
    await typingBox.clear();
    _dbg('Cache cleared');
  }

  static Future<void> clearUserData(String uid) async {
    final key = _userKey(uid);
    await userBox.delete(key);
  }

  static Future<void> clearRoomData(String roomId) async {
    final keys = messageBox.keys.where((k) => k.toString().startsWith(roomId)).toList();
    for (final k in keys) {
      await messageBox.delete(k);
    }
    await chatRoomBox.delete(roomId);
    await gameBox.delete(roomId);
    await typingBox.delete(roomId);
  }

  static Future<void> clearOldCache(Duration maxAge) async {
    final cutoff = DateTime.now().subtract(maxAge);

    final userKeysToDelete = <dynamic>[];
    for (final key in userBox.keys) {
      final item = userBox.get(key);
      if (item != null && item.cachedAt.isBefore(cutoff)) {
        userKeysToDelete.add(key);
      }
    }
    await userBox.deleteAll(userKeysToDelete);

    final roomKeysToDelete = <dynamic>[];
    for (final key in chatRoomBox.keys) {
      final item = chatRoomBox.get(key);
      if (item != null && item.cachedAt.isBefore(cutoff)) {
        roomKeysToDelete.add(key);
      }
    }
    await chatRoomBox.deleteAll(roomKeysToDelete);

    final msgKeysToDelete = <dynamic>[];
    for (final key in messageBox.keys) {
      final item = messageBox.get(key);
      if (item != null && item.cachedAt.isBefore(cutoff)) {
        msgKeysToDelete.add(key);
      }
    }
    await messageBox.deleteAll(msgKeysToDelete);

    _dbg('Old cache cleared (older than ${maxAge.inDays} days)');
  }

  static String _userKey(String uid) => 'user_$uid';

  // ==========================================================================
  // USER CACHE METHODS
  // ==========================================================================

  static Future<UserCache?> getUser(String uid) async {
    if (!isReady) return null;
    try {
      return userBox.get(_userKey(uid));
    } catch (e) {
      _dbg('getUser error: $e');
      return null;
    }
  }

  static Future<List<UserCache>> getUsers(List<String> uids) async {
    if (!isReady) return [];
    try {
      final users = <UserCache>[];
      for (final uid in uids) {
        final user = userBox.get(_userKey(uid));
        if (user != null) users.add(user);
      }
      return users;
    } catch (e) {
      _dbg('getUsers error: $e');
      return [];
    }
  }

  static Future<void> putUser(UserCache user) async {
    if (!isReady) return;
    try {
      await userBox.put(_userKey(user.uid), user);
    } catch (e) {
      _dbg('putUser error: $e');
    }
  }

  static Future<void> putUsers(List<UserCache> users) async {
    if (!isReady) return;
    try {
      final entries = <String, UserCache>{};
      for (final user in users) {
        entries[_userKey(user.uid)] = user;
      }
      await userBox.putAll(entries);
    } catch (e) {
      _dbg('putUsers error: $e');
    }
  }
}

class CacheSyncService {
  static final _firestore = FirebaseFirestore.instance;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[CacheSync] $message');
      return true;
    }());
  }

  static Future<void> syncUserFromFirestore(String uid) async {
    if (!CacheService.isReady) return;

    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (!doc.exists) return;

      final data = doc.data()!;
      final publicKey = data['publicKey'] as Map<String, dynamic>?;

      final cache = UserCache()
        ..uid = uid
        ..name = data['name'] as String?
        ..email = data['email'] as String?
        ..isOnline = data['isOnline'] as bool?
        ..lastSeen = (data['lastSeen'] as Timestamp?)?.toDate()
        ..oneSignalPlayerId = data['oneSignalPlayerId'] as String?
        ..publicKeyN = publicKey?['n'] as String?
        ..publicKeyE = publicKey?['e'] as String?
        ..publicKeyVersion = data['publicKeyVersion'] as String?
        ..cachedAt = DateTime.now()
        ..syncedAt = DateTime.now();

      await CacheService.userBox.put(CacheService._userKey(uid), cache);
      _dbg('synced user $uid to cache');
    } catch (e) {
      _dbg('sync user $uid failed: $e');
    }
  }

  static Future<UserCache?> getCachedUser(String uid) async {
    if (!CacheService.isReady) return null;
    return CacheService.userBox.get(CacheService._userKey(uid));
  }

  static Future<void> syncChatRoomFromFirestore(String roomId) async {
    if (!CacheService.isReady) return;

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
        ..pinnedByCurrentUser = pinnedBy.contains(users.isNotEmpty ? users.first : '')
        ..mutedBy = mutedBy
        ..cachedAt = DateTime.now()
        ..syncedAt = DateTime.now();

      await CacheService.chatRoomBox.put(roomId, cache);
      _dbg('synced chat room $roomId to cache');
    } catch (e) {
      _dbg('sync chat room $roomId failed: $e');
    }
  }

  static Future<ChatRoomCache?> getCachedChatRoom(String roomId) async {
    if (!CacheService.isReady) return null;
    return CacheService.chatRoomBox.get(roomId);
  }

  static Future<List<ChatRoomCache>> getCachedChatRooms(String currentUserId) async {
    if (!CacheService.isReady) return [];
    final allRooms = CacheService.chatRoomBox.values.toList();
    return allRooms
        .where((room) => room.users.contains(currentUserId))
        .toList()
      ..sort((a, b) {
        final aTime = a.lastMessageTime ?? DateTime(1970);
        final bTime = b.lastMessageTime ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
  }

  static Future<void> syncMessageFromFirestore(String roomId, DocumentSnapshot doc) async {
    if (!CacheService.isReady) return;

    try {
      final data = doc.data() as Map<String, dynamic>;
      final key = '${roomId}_${doc.id}';

      final cache = MessageCache()
        ..roomId = roomId
        ..messageId = doc.id
        ..senderId = data['senderId'] as String? ?? ''
        ..receiverId = data['receiverId'] as String? ?? ''
        ..encryptedText = data['text'] as String? ?? ''
        ..encryptedAesKey = data['aesKey'] as String? ?? ''
        ..encryptedAesKeySender = data['aesKeySender'] as String?
        ..iv = data['iv'] as String? ?? ''
        ..senderKeyVersion = data['senderKeyVersion'] as String?
        ..receiverKeyVersion = data['receiverKeyVersion'] as String?
        ..status = data['status'] as String?
        ..timestamp = (data['timestamp'] as Timestamp?)?.toDate()
        ..starred = data['starred'] as bool?
        ..deletedFor = List<String>.from(data['deletedFor'] ?? [])
        ..reactions = Map<String, List<String>>.from(data['reactions'] ?? {})
        ..cachedAt = DateTime.now()
        ..syncedAt = DateTime.now();

      await CacheService.messageBox.put(key, cache);
      _dbg('synced message ${doc.id} to cache');
    } catch (e) {
      _dbg('sync message failed: $e');
    }
  }

  static Future<List<MessageCache>> getCachedMessages(String roomId, {int limit = 100}) async {
    if (!CacheService.isReady) return [];
    return CacheService.messageBox.values
        .where((msg) => msg.roomId == roomId)
        .toList()
      ..sort((a, b) {
        final aTime = a.timestamp ?? DateTime(1970);
        final bTime = b.timestamp ?? DateTime(1970);
        return aTime.compareTo(bTime);
      })
      ..take(limit);
  }

  static Future<void> syncGameFromFirestore(String roomId) async {
    if (!CacheService.isReady) return;

    try {
      final doc = await _firestore.collection('chat_rooms').doc(roomId).get();
      if (!doc.exists) return;

      final data = doc.data()!;
      final gameData = data['game'] as Map<String, dynamic>?;

      if (gameData == null) {
        await CacheService.gameBox.delete(roomId);
        return;
      }

      final cache = GameCache()
        ..roomId = roomId
        ..gameType = gameData['type'] as String?
        ..gameData = gameData
        ..status = gameData['status'] as String?
        ..cachedAt = DateTime.now()
        ..syncedAt = DateTime.now();

      await CacheService.gameBox.put(roomId, cache);
      _dbg('synced game $roomId to cache');
    } catch (e) {
      _dbg('sync game $roomId failed: $e');
    }
  }

  static Future<GameCache?> getCachedGame(String roomId) async {
    if (!CacheService.isReady) return null;
    return CacheService.gameBox.get(roomId);
  }

  static Future<void> syncTypingStatusFromFirestore(String roomId) async {
    if (!CacheService.isReady) return;

    try {
      final doc = await _firestore.collection('chat_rooms').doc(roomId).get();
      if (!doc.exists) return;

      final data = doc.data()!;
      final typingUsers = <String, bool>{};

      for (final key in data.keys) {
        if (key.startsWith('typing_')) {
          final userId = key.substring(7);
          typingUsers[userId] = data[key] as bool? ?? false;
        }
      }

      final cache = TypingStatusCache()
        ..roomId = roomId
        ..typingUsers = typingUsers
        ..cachedAt = DateTime.now();

      await CacheService.typingBox.put(roomId, cache);
    } catch (e) {
      _dbg('sync typing status $roomId failed: $e');
    }
  }

  static Future<TypingStatusCache?> getCachedTypingStatus(String roomId) async {
    if (!CacheService.isReady) return null;
    return CacheService.typingBox.get(roomId);
  }

  static Future<int> getCachedMessageCount(String roomId) async {
    if (!CacheService.isReady) return 0;
    return CacheService.messageBox.values.where((msg) => msg.roomId == roomId).length;
  }
}
