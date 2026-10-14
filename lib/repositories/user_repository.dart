import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../cache/models/user_cache.dart';
import '../cache/cache_service.dart';

/// Repository for user data with stable caching and offline support
/// 
/// Features:
/// - No "User" fallback (uses email prefix or "Unknown")
/// - Stable profile caching with TTL
/// - Offline-safe participant resolution
/// - Automatic hydration from multiple sources
class UserRepository {
  static final UserRepository _instance = UserRepository._internal();
  factory UserRepository() => _instance;
  UserRepository._internal();

  static final _firestore = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;
  
  // In-memory cache for fast access
  static final Map<String, _CachedUserProfile> _memoryCache = {};
  
  // Track loading states to prevent duplicate requests
  static final Set<String> _loadingUserIds = {};
  static final Set<String> _failedUserIds = {};
  
  // Stream controllers for reactive updates
  static final _userUpdatesController = StreamController<String>.broadcast();
  static Stream<String> get userUpdates => _userUpdatesController.stream;
  
  // Cache TTL
  static const Duration _cacheTTL = Duration(minutes: 10);
  static const Duration _failedCacheTTL = Duration(minutes: 2);
  
  // ==========================================================================
  // USER PROFILE RESOLUTION
  // ==========================================================================
  
  /// Gets user profile with guaranteed hydration
  /// 
  /// Tries in order:
  /// 1. Memory cache (fastest)
  /// 2. Local persistent cache (Isar)
  /// 3. Firestore (source of truth)
  /// 4. Fallback to email-based name or "Unknown"
  /// 
  /// Never returns "User" as fallback
  static Future<UserProfile> getUserProfile(String userId) async {
    // Check memory cache first
    final cached = _memoryCache[userId];
    if (cached != null && cached.isValid) {
      debugPrint('[UserRepository] Memory cache hit for $userId');
      return cached.toProfile();
    }
    
    // Skip if already loading
    if (_loadingUserIds.contains(userId)) {
      debugPrint('[UserRepository] Already loading $userId, returning pending');
      return UserProfile.pending(userId);
    }
    
    // Skip if recently failed
    if (_failedUserIds.contains(userId)) {
      debugPrint('[UserRepository] Recently failed for $userId, trying cache only');
      final cacheOnly = await _getFromCacheOnly(userId);
      if (cacheOnly != null) return cacheOnly;
      return UserProfile.unknown(userId);
    }
    
    _loadingUserIds.add(userId);
    
    try {
      // Try local cache (Isar)
      final localCache = await _getFromIsar(userId);
      if (localCache != null) {
        _memoryCache[userId] = _CachedUserProfile.fromProfile(localCache);
        debugPrint('[UserRepository] Isar cache hit for $userId');
        _loadingUserIds.remove(userId);
        return localCache;
      }
      
      // Try Firestore
      final firestoreProfile = await _getFromFirestore(userId);
      if (firestoreProfile != null) {
        // Update both caches
        _memoryCache[userId] = _CachedUserProfile.fromProfile(firestoreProfile);
        await _saveToIsar(firestoreProfile);
        _userUpdatesController.add(userId);
        debugPrint('[UserRepository] Firestore hit for $userId');
        _loadingUserIds.remove(userId);
        return firestoreProfile;
      }
      
      // No data found - try to get email from auth
      final email = await _getUserEmail(userId);
      if (email != null) {
        final emailBasedProfile = UserProfile.fromEmail(userId, email);
        _memoryCache[userId] = _CachedUserProfile.fromProfile(emailBasedProfile);
        await _saveToIsar(emailBasedProfile);
        debugPrint('[UserRepository] Created email-based profile for $userId');
        _loadingUserIds.remove(userId);
        return emailBasedProfile;
      }
      
      // Ultimate fallback - unknown
      debugPrint('[UserRepository] No data for $userId, returning unknown');
      _failedUserIds.add(userId);
      _scheduleFailedRetry(userId);
      _loadingUserIds.remove(userId);
      return UserProfile.unknown(userId);
      
    } catch (e) {
      debugPrint('[UserRepository] Error loading $userId: $e');
      _failedUserIds.add(userId);
      _scheduleFailedRetry(userId);
      _loadingUserIds.remove(userId);
      
      // Try to return any cached data even if expired
      final expiredCache = _memoryCache[userId];
      if (expiredCache != null) {
        return expiredCache.toProfile();
      }
      
      return UserProfile.unknown(userId);
    }
  }
  
  /// Gets multiple user profiles efficiently (batched)
  static Future<Map<String, UserProfile>> getUserProfiles(
    List<String> userIds,
  ) async {
    final results = <String, UserProfile>{};
    final futures = <Future<void>>[];
    
    for (final userId in userIds.toSet()) {
      futures.add(() async {
        results[userId] = await getUserProfile(userId);
      }());
    }
    
    await Future.wait(futures);
    return results;
  }
  
  /// Preloads user profiles into cache (for chat list)
  static Future<void> preloadUserProfiles(List<String> userIds) async {
    final uniqueIds = userIds.where((id) => 
      !_memoryCache.containsKey(id) && 
      !_loadingUserIds.contains(id)
    ).toList();
    
    if (uniqueIds.isEmpty) return;
    
    debugPrint('[UserRepository] Preloading ${uniqueIds.length} user profiles');
    
    // Load from Isar in batch
    try {
      final cached = await CacheService.getUsers(uniqueIds);
      for (final user in cached) {
        _memoryCache[user.uid] = _CachedUserProfile(
          uid: user.uid,
          name: user.name,
          email: user.email,
          isOnline: user.isOnline ?? false,
          lastSeen: user.lastSeen,
          cachedAt: user.cachedAt,
        );
      }
    } catch (e) {
      debugPrint('[UserRepository] Error preloading from Isar: $e');
    }
    
    // Load remaining from Firestore in background
    final remaining = uniqueIds.where((id) => !_memoryCache.containsKey(id)).toList();
    if (remaining.isNotEmpty) {
      Future.microtask(() async {
        for (final userId in remaining) {
          await getUserProfile(userId);
        }
      });
    }
  }
  
  // ==========================================================================
  // CACHE MANAGEMENT
  // ==========================================================================
  
  /// Updates user profile in cache and persists
  static Future<void> updateUserProfile(UserProfile profile) async {
    _memoryCache[profile.uid] = _CachedUserProfile.fromProfile(profile);
    await _saveToIsar(profile);
    _userUpdatesController.add(profile.uid);
    debugPrint('[UserRepository] Updated profile for ${profile.uid}');
  }
  
  /// Invalidates user cache (call when user data changes)
  static void invalidateUserCache(String userId) {
    _memoryCache.remove(userId);
    _failedUserIds.remove(userId);
    debugPrint('[UserRepository] Invalidated cache for $userId');
  }
  
  /// Clears all caches
  static void clearAllCaches() {
    _memoryCache.clear();
    _failedUserIds.clear();
    _loadingUserIds.clear();
    debugPrint('[UserRepository] All caches cleared');
  }
  
  /// Gets cache statistics
  static Map<String, dynamic> getCacheStats() {
    return {
      'memoryCacheSize': _memoryCache.length,
      'failedCacheSize': _failedUserIds.length,
      'loadingCount': _loadingUserIds.length,
      'validEntries': _memoryCache.values.where((c) => c.isValid).length,
    };
  }
  
  // ==========================================================================
  // PRIVATE METHODS
  // ==========================================================================
  
  static Future<UserProfile?> _getFromCacheOnly(String userId) async {
    // Try memory cache (even if expired)
    final memCache = _memoryCache[userId];
    if (memCache != null) return memCache.toProfile();
    
    // Try Isar cache
    return await _getFromIsar(userId);
  }
  
  static Future<UserProfile?> _getFromIsar(String userId) async {
    try {
      final user = await CacheService.getUser(userId);
      if (user == null) return null;
      
      return UserProfile(
        uid: user.uid,
        name: user.name,
        email: user.email,
        isOnline: user.isOnline ?? false,
        lastSeen: user.lastSeen,
        publicKeyN: user.publicKeyN,
        publicKeyE: user.publicKeyE,
        cachedAt: user.cachedAt,
      );
    } catch (e) {
      debugPrint('[UserRepository] Isar error: $e');
      return null;
    }
  }
  
  static Future<UserProfile?> _getFromFirestore(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (!doc.exists || doc.data() == null) return null;
      
      final data = doc.data()!;
      
      // Safe parsing - no "User" fallback
      final name = _parseString(data['name']);
      final email = _parseString(data['email']);
      
      return UserProfile(
        uid: userId,
        name: name.isNotEmpty ? name : null,
        email: email.isNotEmpty ? email : null,
        isOnline: data['isOnline'] as bool? ?? false,
        lastSeen: _parseTimestamp(data['lastSeen']),
        publicKeyN: _parseString(data['publicKey']?['n']),
        publicKeyE: _parseString(data['publicKey']?['e']),
        cachedAt: DateTime.now(),
        syncedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('[UserRepository] Firestore error: $e');
      return null;
    }
  }
  
  static Future<void> _saveToIsar(UserProfile profile) async {
    try {
      final cache = UserCache()
        ..uid = profile.uid
        ..name = profile.name
        ..email = profile.email
        ..isOnline = profile.isOnline
        ..lastSeen = profile.lastSeen
        ..publicKeyN = profile.publicKeyN
        ..publicKeyE = profile.publicKeyE
        ..cachedAt = DateTime.now()
        ..syncedAt = DateTime.now();
      
      await CacheService.putUser(cache);
    } catch (e) {
      debugPrint('[UserRepository] Error saving to Isar: $e');
    }
  }
  
  static Future<String?> _getUserEmail(String userId) async {
    // Try current user
    final currentUser = _auth.currentUser;
    if (currentUser?.uid == userId) {
      return currentUser?.email;
    }
    
    // Try cache
    final cached = _memoryCache[userId];
    if (cached?.email != null) return cached!.email;
    
    return null;
  }
  
  static void _scheduleFailedRetry(String userId) {
    Future.delayed(_failedCacheTTL, () {
      _failedUserIds.remove(userId);
      debugPrint('[UserRepository] Retry scheduled for $userId');
    });
  }
  
  // ==========================================================================
  // PARSING UTILITIES
  // ==========================================================================
  
  static String _parseString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }
  
  static DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }
}

// ============================================================================
// USER PROFILE MODEL
// ============================================================================

/// Immutable user profile data
class UserProfile {
  final String uid;
  final String? name;
  final String? email;
  final bool isOnline;
  final DateTime? lastSeen;
  final String? publicKeyN;
  final String? publicKeyE;
  final DateTime cachedAt;
  final DateTime? syncedAt;
  final bool isPending;
  final bool isUnknown;
  
  const UserProfile({
    required this.uid,
    this.name,
    this.email,
    this.isOnline = false,
    this.lastSeen,
    this.publicKeyN,
    this.publicKeyE,
    required this.cachedAt,
    this.syncedAt,
    this.isPending = false,
    this.isUnknown = false,
  });
  
  /// Creates from email (uses prefix as name)
  factory UserProfile.fromEmail(String uid, String email) {
    final name = email.split('@').first;
    return UserProfile(
      uid: uid,
      name: name,
      email: email,
      cachedAt: DateTime.now(),
    );
  }
  
  /// Pending state (while loading)
  factory UserProfile.pending(String uid) {
    return UserProfile(
      uid: uid,
      name: null,
      cachedAt: DateTime.now(),
      isPending: true,
    );
  }
  
  /// Unknown state (no data available)
  factory UserProfile.unknown(String uid) {
    return UserProfile(
      uid: uid,
      name: null,
      cachedAt: DateTime.now(),
      isUnknown: true,
    );
  }
  
  /// Display name for UI (never returns "User")
  String get displayName {
    if (name != null && name!.isNotEmpty) return name!;
    if (email != null && email!.isNotEmpty) {
      return email!.split('@').first;
    }
    if (isUnknown) return 'Unknown';
    if (isPending) return 'Loading...';
    return 'Unknown User';
  }
  
  /// Avatar text (initials)
  String get avatarText {
    final nameToUse = name ?? email?.split('@').first ?? '?';
    if (nameToUse.isEmpty) return '?';
    return nameToUse.substring(0, 1).toUpperCase();
  }
  
  /// Whether profile is hydrated with real data
  bool get isHydrated => !isUnknown && !isPending;
  
  /// Creates copy with updated fields
  UserProfile copyWith({
    String? uid,
    String? name,
    String? email,
    bool? isOnline,
    DateTime? lastSeen,
    String? publicKeyN,
    String? publicKeyE,
    DateTime? cachedAt,
    DateTime? syncedAt,
    bool? isPending,
    bool? isUnknown,
  }) {
    return UserProfile(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      email: email ?? this.email,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
      publicKeyN: publicKeyN ?? this.publicKeyN,
      publicKeyE: publicKeyE ?? this.publicKeyE,
      cachedAt: cachedAt ?? this.cachedAt,
      syncedAt: syncedAt ?? this.syncedAt,
      isPending: isPending ?? this.isPending,
      isUnknown: isUnknown ?? this.isUnknown,
    );
  }
  
  @override
  String toString() => 'UserProfile(uid: $uid, name: $displayName)';
}

// ============================================================================
// INTERNAL CACHE STRUCTURE
// ============================================================================

class _CachedUserProfile {
  final String uid;
  final String? name;
  final String? email;
  final bool isOnline;
  final DateTime? lastSeen;
  final DateTime cachedAt;
  
  _CachedUserProfile({
    required this.uid,
    this.name,
    this.email,
    this.isOnline = false,
    this.lastSeen,
    required this.cachedAt,
  });
  
  factory _CachedUserProfile.fromProfile(UserProfile profile) {
    return _CachedUserProfile(
      uid: profile.uid,
      name: profile.name,
      email: profile.email,
      isOnline: profile.isOnline,
      lastSeen: profile.lastSeen,
      cachedAt: profile.cachedAt,
    );
  }
  
  bool get isValid {
    return DateTime.now().difference(cachedAt) < UserRepository._cacheTTL;
  }
  
  UserProfile toProfile() {
    return UserProfile(
      uid: uid,
      name: name,
      email: email,
      isOnline: isOnline,
      lastSeen: lastSeen,
      cachedAt: cachedAt,
    );
  }
}
