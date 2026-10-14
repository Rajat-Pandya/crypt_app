import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Real-time presence service using Firebase Realtime Database
///
/// Provides reliable online/offline detection using Realtime Database's
/// onDisconnect() hook, which automatically fires when the client disconnects
/// (even on crashes, airplane mode, etc.)
///
/// Flow:
/// 1. User comes online -> set presence in RTDB with onDisconnect handler
/// 2. User goes offline (lifecycle) -> clear presence manually
/// 3. User loses connection unexpectedly -> onDisconnect fires automatically
/// 4. Other clients listen to RTDB presence and sync to Firestore
class PresenceService {
  static final FirebaseDatabase _rtdb = FirebaseDatabase.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  
  static bool _isInitialized = false;
  static StreamSubscription<DatabaseEvent>? _presenceSub;
  static Timer? _heartbeatTimer;
  static String? _currentUid;
  
  // Configuration
  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _presenceTimeout = Duration(seconds: 60);
  static const String _presencePath = 'presence';
  
  /// Initialize presence tracking for the current user
  /// 
  /// NOTE: RTDB presence is disabled if databaseURL is not configured
  /// to prevent connection errors. Falls back to Firestore-only presence.
  static Future<void> initialize() async {
    if (_isInitialized) return;
    
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[PresenceService] initialize: no user logged in');
      return;
    }
    
    _currentUid = user.uid;
    
    try {
      debugPrint('[PresenceService] initialize: START - uid: $_currentUid');
      
      // Check if RTDB is configured - if not, use Firestore-only fallback
      final dbUrl = _rtdb.databaseURL;
      if (dbUrl == null || dbUrl.isEmpty) {
        debugPrint('[PresenceService] RTDB not configured, using Firestore-only presence');
        // Firestore-only fallback - just sync presence to Firestore
        await _syncPresenceToFirestore(true);
        _isInitialized = true;
        return;
      }
      
      // Set up onDisconnect handler in Realtime Database
      await _setupOnDisconnect();
      
      // Set initial presence
      await _setPresence(true);
      
      // Start heartbeat timer
      _startHeartbeat();
      
      // Sync presence to Firestore for queryability
      await _syncPresenceToFirestore(true);
      
      _isInitialized = true;
      debugPrint('[PresenceService] initialize: SUCCESS');
    } catch (e) {
      debugPrint('[PresenceService] initialize: ERROR - $e');
      debugPrint('[PresenceService] Disabling RTDB presence, using Firestore fallback');
      // Fallback: just update Firestore presence
      try {
        await _syncPresenceToFirestore(true);
      } catch (_) {}
    }
  }
  
  /// Set up onDisconnect handler - this automatically fires when client disconnects
  static Future<void> _setupOnDisconnect() async {
    if (_currentUid == null) return;
    
    try {
      final presenceRef = _rtdb.ref().child('$_presencePath/$_currentUid');
      
      // Configure onDisconnect to set offline
      await presenceRef.onDisconnect().update({
        'isOnline': false,
        'lastSeen': ServerValue.timestamp,
        'disconnectReason': 'client_disconnected',
      });
      
      debugPrint('[PresenceService] _setupOnDisconnect: onDisconnect handler set');
    } catch (e) {
      debugPrint('[PresenceService] _setupOnDisconnect: ERROR - $e');
    }
  }
  
  /// Set presence status in Realtime Database
  static Future<void> _setPresence(bool isOnline) async {
    if (_currentUid == null) return;
    
    try {
      final presenceRef = _rtdb.ref().child('$_presencePath/$_currentUid');
      
      await presenceRef.update({
        'isOnline': isOnline,
        'lastSeen': ServerValue.timestamp,
        'platform': 'flutter',
      });
      
      debugPrint('[PresenceService] _setPresence: isOnline=$isOnline');
    } catch (e) {
      debugPrint('[PresenceService] _setPresence: ERROR - $e');
    }
  }
  
  /// Sync presence status to Firestore (for queryability)
  static Future<void> _syncPresenceToFirestore(bool isOnline) async {
    if (_currentUid == null) return;
    
    try {
      await _firestore.collection('users').doc(_currentUid).update({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
        'presenceSource': 'rtdb',
        'presenceUpdatedAt': FieldValue.serverTimestamp(),
      });
      
      debugPrint('[PresenceService] _syncPresenceToFirestore: synced');
    } catch (e) {
      debugPrint('[PresenceService] _syncPresenceToFirestore: ERROR - $e');
    }
  }
  
  /// Start heartbeat timer to keep presence fresh
  static void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      if (_currentUid == null) return;
      
      try {
        // Update RTDB presence
        await _setPresence(true);
        
        // Periodic sync to Firestore (every other heartbeat)
        if (DateTime.now().second % 60 < 30) {
          await _syncPresenceToFirestore(true);
        }
        
        debugPrint('[PresenceService] _startHeartbeat: heartbeat sent');
      } catch (e) {
        debugPrint('[PresenceService] _startHeartbeat: ERROR - $e');
      }
    });
    
    debugPrint('[PresenceService] _startHeartbeat: timer started');
  }
  
  /// Set user as offline (call when app goes to background)
  static Future<void> setOffline() async {
    if (!_isInitialized || _currentUid == null) return;
    
    try {
      debugPrint('[PresenceService] setOffline: START');
      
      // Cancel onDisconnect handler since we're intentionally going offline
      final presenceRef = _rtdb.ref().child('$_presencePath/$_currentUid');
      await presenceRef.onDisconnect().cancel();
      
      // Set offline status
      await presenceRef.update({
        'isOnline': false,
        'lastSeen': ServerValue.timestamp,
        'disconnectReason': 'app_backgrounded',
      });
      
      // Sync to Firestore
      await _syncPresenceToFirestore(false);
      
      // Cancel heartbeat
      _heartbeatTimer?.cancel();
      
      debugPrint('[PresenceService] setOffline: SUCCESS');
    } catch (e) {
      debugPrint('[PresenceService] setOffline: ERROR - $e');
    }
  }
  
  /// Set user as online (call when app comes to foreground)
  static Future<void> setOnline() async {
    if (_currentUid == null) return;
    
    try {
      debugPrint('[PresenceService] setOnline: START');
      
      // Reset onDisconnect handler
      await _setupOnDisconnect();
      
      // Set online status
      await _setPresence(true);
      
      // Sync to Firestore
      await _syncPresenceToFirestore(true);
      
      // Restart heartbeat if needed
      if (_heartbeatTimer?.isActive != true) {
        _startHeartbeat();
      }
      
      debugPrint('[PresenceService] setOnline: SUCCESS');
    } catch (e) {
      debugPrint('[PresenceService] setOnline: ERROR - $e');
    }
  }
  
  /// Listen to another user's presence status
  static Stream<PresenceStatus> listenToUserPresence(String userId) {
    final presenceRef = _rtdb.ref().child('$_presencePath/$userId');
    
    return presenceRef.onValue.map((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      
      if (data == null) {
        return PresenceStatus(
          userId: userId,
          isOnline: false,
          lastSeen: null,
        );
      }
      
      final isOnline = data['isOnline'] as bool? ?? false;
      final lastSeenMs = data['lastSeen'] as int?;
      final lastSeen = lastSeenMs != null 
          ? DateTime.fromMillisecondsSinceEpoch(lastSeenMs)
          : null;
      
      // Check if presence is stale (>60 seconds old)
      final isStale = lastSeen != null && 
          DateTime.now().difference(lastSeen) > _presenceTimeout;
      
      return PresenceStatus(
        userId: userId,
        isOnline: isOnline && !isStale,
        lastSeen: lastSeen,
        isStale: isStale,
      );
    });
  }
  
  /// Get current presence status for a user (one-time)
  static Future<PresenceStatus> getUserPresence(String userId) async {
    try {
      final snapshot = await _rtdb.ref().child('$_presencePath/$userId').get();
      
      if (!snapshot.exists) {
        return PresenceStatus(
          userId: userId,
          isOnline: false,
          lastSeen: null,
        );
      }
      
      final data = snapshot.value as Map<dynamic, dynamic>;
      final isOnline = data['isOnline'] as bool? ?? false;
      final lastSeenMs = data['lastSeen'] as int?;
      final lastSeen = lastSeenMs != null 
          ? DateTime.fromMillisecondsSinceEpoch(lastSeenMs)
          : null;
      
      final isStale = lastSeen != null && 
          DateTime.now().difference(lastSeen) > _presenceTimeout;
      
      return PresenceStatus(
        userId: userId,
        isOnline: isOnline && !isStale,
        lastSeen: lastSeen,
        isStale: isStale,
      );
    } catch (e) {
      debugPrint('[PresenceService] getUserPresence: ERROR - $e');
      return PresenceStatus(
        userId: userId,
        isOnline: false,
        lastSeen: null,
      );
    }
  }
  
  /// Cleanup presence service
  static Future<void> dispose() async {
    debugPrint('[PresenceService] dispose: START');
    
    // Set offline before disposing
    await setOffline();
    
    // Cancel subscriptions
    await _presenceSub?.cancel();
    _presenceSub = null;
    
    // Cancel timer
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    
    _isInitialized = false;
    _currentUid = null;
    
    debugPrint('[PresenceService] dispose: END');
  }
  
  /// Check if presence service is initialized
  static bool get isInitialized => _isInitialized;
  
  /// Get current user ID
  static String? get currentUid => _currentUid;
}

/// Presence status data class
class PresenceStatus {
  final String userId;
  final bool isOnline;
  final DateTime? lastSeen;
  final bool isStale;
  final String? disconnectReason;
  
  const PresenceStatus({
    required this.userId,
    required this.isOnline,
    this.lastSeen,
    this.isStale = false,
    this.disconnectReason,
  });
  
  /// Get a human-readable status
  String get displayStatus {
    if (isOnline) return 'Online';
    if (lastSeen == null) return 'Offline';
    
    final diff = DateTime.now().difference(lastSeen!);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
    return 'Last seen ${diff.inDays}d ago';
  }
}
