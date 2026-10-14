import 'package:flutter/foundation.dart';

/// Caches room IDs to prevent repeated calculations.
/// 
/// Room IDs are deterministic (sorted user IDs joined by "_"),
/// so they can be safely cached for the app lifecycle.
class RoomIdCache {
  static final RoomIdCache _instance = RoomIdCache._internal();
  factory RoomIdCache() => _instance;
  RoomIdCache._internal();

  // Cache: (userId1, userId2) -> roomId
  final Map<String, String> _roomIdCache = {};
  
  // Reverse cache: roomId -> (userId1, userId2)
  final Map<String, List<String>> _roomToUsers = {};
  
  // Stats
  int _hitCount = 0;
  int _missCount = 0;

  static void _logCache(String message) {
    assert(() {
      debugPrint('[CACHE] $message');
      return true;
    }());
  }

  /// Generate room ID with caching.
  /// 
  /// Returns cached result if available, otherwise calculates and caches.
  String getRoomId(String u1, String u2) {
    // Create consistent cache key (sorted)
    final cacheKey = _getCacheKey(u1, u2);
    
    // Check cache
    if (_roomIdCache.containsKey(cacheKey)) {
      _hitCount++;
      return _roomIdCache[cacheKey]!;
    }

    _missCount++;
    
    // Calculate room ID
    final users = [u1, u2]..sort();
    final roomId = users.join('_');
    
    // Cache it
    _roomIdCache[cacheKey] = roomId;
    _roomToUsers[roomId] = [users[0], users[1]];
    
    return roomId;
  }

  /// Get room ID without caching (for one-off use)
  String calculateRoomId(String u1, String u2) {
    final users = [u1, u2]..sort();
    return users.join('_');
  }

  /// Get users from room ID
  List<String>? getUsersFromRoomId(String roomId) {
    return _roomToUsers[roomId];
  }

  /// Check if room ID is cached
  bool isCached(String u1, String u2) {
    final cacheKey = _getCacheKey(u1, u2);
    return _roomIdCache.containsKey(cacheKey);
  }

  /// Pre-cache room IDs for a list of user pairs
  void preloadRoomIds(List<List<String>> userPairs) {
    for (final pair in userPairs) {
      if (pair.length >= 2) {
        getRoomId(pair[0], pair[1]);
      }
    }
    _logCache('Preloaded ${userPairs.length} room IDs');
  }

  /// Create consistent cache key
  String _getCacheKey(String u1, String u2) {
    // Always sort for consistency
    final sorted = u1.compareTo(u2) < 0 ? [u1, u2] : [u2, u1];
    return '${sorted[0]}_${sorted[1]}';
  }

  /// Clear all caches
  void clear() {
    _roomIdCache.clear();
    _roomToUsers.clear();
    _hitCount = 0;
    _missCount = 0;
    _logCache('Cleared room ID cache');
  }

  /// Get cache statistics
  Map<String, dynamic> getStats() {
    return {
      'cacheSize': _roomIdCache.length,
      'hitCount': _hitCount,
      'missCount': _missCount,
      'hitRate': _hitCount + _missCount > 0
          ? '${(_hitCount / (_hitCount + _missCount) * 100).toStringAsFixed(1)}%'
          : 'N/A',
    };
  }

  /// Get cache size
  int get size => _roomIdCache.length;
}

/// Extension for easy room ID access
extension RoomIdCacheExtension on RoomIdCache {
  /// Get room ID and log if cache miss
  String getRoomIdLogged(String u1, String u2) {
    final wasCached = isCached(u1, u2);
    final roomId = getRoomId(u1, u2);
    
    if (!wasCached) {
      RoomIdCache._logCache('Cache miss for room: $roomId');
    }
    
    return roomId;
  }
}
