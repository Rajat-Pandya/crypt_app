import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:http/http.dart' as http;

import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';
import '../fallback/firestore_stubs.dart';
import '../config/app_config.dart';
import 'telemetry_service.dart';
import 'dart:async' show TimeoutException;

/// Re-export stub classes for backward compatibility
export '../fallback/firestore_stubs.dart' show FakeSnapshotMetadata, StubQuerySnapshot;

/// Chat utility service for non-message-sending operations
/// 
/// This service provides utility methods for chat functionality including:
/// - Room management (bootstrap, stream creation)
/// - Typing indicators
/// - Read receipts (delivered/seen)
/// - Message reactions
/// - Delete operations (for me/everyone)
/// - Notification sending
/// - User blocking
/// - Starred messages
/// - Chat muting
/// 
/// For sending messages, use SecureChatService instead.
class ChatUtilService {
  static final _firestore = FirebaseFirestore.instance;
  static final _storage = const FlutterSecureStorage();

  static void _dbg(String message) {
    assert(() {
      debugPrint('[ChatUtilService] $message');
      return true;
    }());
  }

  // ==========================================================================
  // ROOM MANAGEMENT
  // ==========================================================================

  /// Generates a consistent room ID from two user IDs
  static String getRoomId(String u1, String u2) {
    debugPrint('[ChatUtilService] getRoomId: START - u1: $u1, u2: $u2');
    final users = [u1, u2]..sort();
    final roomId = users.join('_');
    debugPrint('[ChatUtilService] getRoomId: SUCCESS - roomId: $roomId');
    debugPrint('[ChatUtilService] getRoomId: END');
    return roomId;
  }

  /// Initialize ChatService and log configuration status
  /// 
  /// Call this during app startup to verify push notification configuration.
  static void initialize() {
    debugPrint('╔══════════════════════════════════════════════════════════════════╗');
    debugPrint('║ ChatUtilService Initialization                                       ║');
    debugPrint('╠══════════════════════════════════════════════════════════════════╣');
    
    final config = checkNotificationConfig();
    if (config['isValid'] == true) {
      debugPrint('║ Push Notifications: CONFIGURED ✓                               ║');
      debugPrint('║ CF Worker URL: ${AppConfig.cfWorkerUrl.substring(0, min(40, AppConfig.cfWorkerUrl.length))}...');
    } else {
      debugPrint('║ Push Notifications: DISABLED ⚠                                   ║');
      debugPrint('║ ${config['error']}');
      if (config.containsKey('hint')) {
        debugPrint('║ Hint: ${config['hint']}');
      }
    }
    
    debugPrint('╚══════════════════════════════════════════════════════════════════╝');
  }

  /// Bootstrap a chat room before starting message stream
  /// CRITICAL: Creates room document if missing to prevent permission-denied errors
  static Future<bool> bootstrapRoom({
    required String currentUserId,
    required String receiverId,
  }) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: START - roomId=$chatRoomId, currentUser=$currentUserId, receiver=$receiverId');
    
    try {
      // First check if room exists
      final roomRef = _firestore.collection('chat_rooms').doc(chatRoomId);
      final roomDoc = await roomRef.get().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: TIMEOUT checking room existence');
          throw TimeoutException('Room check timed out');
        },
      );
      
      if (roomDoc.exists) {
        debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: Room exists, no bootstrap needed');
        return true;
      }
      
      // Room doesn't exist - create it with minimal data
      debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: Room missing, creating...');
      
      await roomRef.set({
        'users': [currentUserId, receiverId],
        'participants': [currentUserId, receiverId], // Dual field for compatibility
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': currentUserId,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessage': '',
        'typing_$currentUserId': false,
        'typing_$receiverId': false,
        'lastSeen_$currentUserId': FieldValue.serverTimestamp(),
        'lastSeen_$receiverId': null,
      }, SetOptions(merge: true));
      
      debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: SUCCESS - Room created');
      return true;
      
    } on FirebaseException catch (e) {
      debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: FirebaseException - ${e.code}: ${e.message}');
      if (e.code == 'permission-denied') {
        debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: PERMISSION DENIED - rules may need update');
      }
      return false;
    } catch (e) {
      debugPrint('[CHAT_BOOTSTRAP] bootstrapRoom: ERROR - ${e.runtimeType}: $e');
      return false;
    }
  }

  /// Ensures room exists before starting message stream
  /// Returns stream that handles permission errors gracefully
  static Stream<QuerySnapshot<Map<String, dynamic>>> getMessageStream({
    required String currentUserId,
    required String receiverId,
  }) {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    debugPrint('[MESSAGE_STREAM] getMessageStream: START - roomId=$chatRoomId');
    
    // Try to bootstrap room first, then return stream
    return Stream.fromFuture(
      bootstrapRoom(currentUserId: currentUserId, receiverId: receiverId),
    ).asyncExpand((bootstrapped) {
      debugPrint('[MESSAGE_STREAM] getMessageStream: bootstrapped=$bootstrapped');
      
      // Return the actual message stream
      // includeMetadataChanges: true ensures local writes trigger updates (offline support)
      return _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .orderBy('timestamp')
          .limitToLast(100)
          .snapshots(includeMetadataChanges: true)
          .handleError((error) {
            debugPrint('[MESSAGE_STREAM] getMessageStream: ERROR - $error');
            if (error is FirebaseException) {
              debugPrint('[MESSAGE_STREAM] getMessageStream: FirebaseException code=${error.code}');
              if (error.code == 'permission-denied') {
                debugPrint('[PERMISSION] Message stream permission denied for room=$chatRoomId');
              }
            }
            // Return empty stream on error - StreamBuilder will show empty state
            return Stream.value(StubQuerySnapshot<Map<String, dynamic>>());
          });
    });
  }

  // ==========================================================================
  // KEY LOADING
  // ==========================================================================

  static Future<PublicKeyResult?> loadReceiverPublicKey(
    String receiverId, {
    bool forceServer = false,
  }) async {
    debugPrint('[ChatUtilService] loadReceiverPublicKey: START - receiverId: $receiverId, forceServer: $forceServer');
    try {
      DocumentSnapshot<Map<String, dynamic>> doc;
      if (forceServer) {
        debugPrint('[ChatUtilService] loadReceiverPublicKey: forcing server fetch');
        try {
          doc = await _firestore
              .collection('users')
              .doc(receiverId)
              .get(const GetOptions(source: Source.server));
          debugPrint('[ChatUtilService] loadReceiverPublicKey: server fetch completed');
        } on FirebaseException catch (e) {
          debugPrint('[ChatUtilService] loadReceiverPublicKey: server fetch failed, falling back to cache - ${e.runtimeType}: $e');
          // Offline — fall back to cache rather than returning null
          doc = await _firestore
              .collection('users')
              .doc(receiverId)
              .get(const GetOptions(source: Source.cache));
          debugPrint('[ChatUtilService] loadReceiverPublicKey: cache fetch completed');
        }
      } else {
        debugPrint('[ChatUtilService] loadReceiverPublicKey: using serverAndCache');
        doc = await _firestore
            .collection('users')
            .doc(receiverId)
            .get(const GetOptions(source: Source.serverAndCache));
        debugPrint('[ChatUtilService] loadReceiverPublicKey: fetch completed');
      }
      final data = doc.data();

      // User doesn't exist at all
      if (data == null) {
        debugPrint('[ChatUtilService] loadReceiverPublicKey: ERROR - user $receiverId does not exist');
        debugPrint('[ChatUtilService] loadReceiverPublicKey: END');
        return null;
      }

      // User exists but no publicKey yet (not fully registered)
      if (data['publicKey'] == null) {
        debugPrint('[ChatUtilService] loadReceiverPublicKey: ERROR - user exists but no public key yet');
        debugPrint('[ChatUtilService] loadReceiverPublicKey: END');
        return null;
      }

      final keyData = data['publicKey'] as Map<String, dynamic>;
      final version = data['publicKeyVersion'] as String? ?? 'v1';

      debugPrint(
        '[ChatUtilService] loadReceiverPublicKey: SUCCESS - loaded key version=$version for $receiverId',
      );

      final result = PublicKeyResult(
        publicKey: RSAPublicKey(
          BigInt.parse(keyData['n'] as String),
          BigInt.parse(keyData['e'] as String),
        ),
        version: version,
      );
      debugPrint('[ChatUtilService] loadReceiverPublicKey: END');
      return result;
    } catch (e) {
      debugPrint('[ChatUtilService] loadReceiverPublicKey: ERROR - ${e.runtimeType}: $e');
      debugPrint('[ChatUtilService] loadReceiverPublicKey: END');
      return null;
    }
  }

  static Future<String?> loadPrivateKey() async {
    debugPrint('[ChatUtilService] loadPrivateKey: START');
    try {
      // First check for device-specific key (post-approval)
      final deviceKey = await _storage.read(key: 'device_private_key');
      if (deviceKey != null) {
        debugPrint('[ChatUtilService] loadPrivateKey: SUCCESS - loaded device_private_key');
        debugPrint('[ChatUtilService] loadPrivateKey: END');
        return deviceKey;
      }
      
      // Fall back to legacy key (pre-approval or backup restored)
      final legacyKey = await _storage.read(key: 'private_key');
      if (legacyKey != null) {
        debugPrint('[ChatUtilService] loadPrivateKey: SUCCESS - loaded legacy private_key, migrating...');
        // Migrate to device-specific storage for consistency
        await _storage.write(key: 'device_private_key', value: legacyKey);
        debugPrint('[ChatUtilService] loadPrivateKey: Migrated legacy key to device_private_key');
        debugPrint('[ChatUtilService] loadPrivateKey: END');
        return legacyKey;
      }
      
      debugPrint('[ChatUtilService] loadPrivateKey: WARNING - no private key found');
      debugPrint('[ChatUtilService] loadPrivateKey: END');
      return null;
    } catch (e) {
      debugPrint('[ChatUtilService] loadPrivateKey: ERROR - ${e.runtimeType}: $e');
      debugPrint('[ChatUtilService] loadPrivateKey: END');
      return null;
    }
  }

  // ==========================================================================
  // TYPING INDICATORS
  // ==========================================================================

  static Future<void> updateTyping(
    String currentUserId,
    String receiverId,
    bool typing,
  ) async {
    debugPrint('[ChatUtilService] updateTyping: START - currentUserId: $currentUserId, receiverId: $receiverId, typing: $typing');
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      final updateData = <String, dynamic>{
        'typing_$currentUserId': typing,
      };
      
      // Only set timestamp when starting to type, clear it when stopping
      if (typing) {
        updateData['typingTimestamp_$currentUserId'] = FieldValue.serverTimestamp();
      } else {
        updateData['typingTimestamp_$currentUserId'] = null;
      }
      
      await _firestore.collection('chat_rooms').doc(chatRoomId).update(updateData);
      debugPrint('[ChatUtilService] updateTyping: SUCCESS - typing status updated');
    } catch (e) {
      debugPrint('[ChatUtilService] updateTyping: ERROR - ${e.runtimeType}: $e');
      // Silently ignore — typing is non-critical (room may not exist yet)
    }
    debugPrint('[ChatUtilService] updateTyping: END');
  }

  /// Clears stale typing indicators that may be stuck due to app crashes
  static Future<void> clearStaleTypingIndicators(
    String currentUserId,
    String receiverId,
  ) async {
    debugPrint('[ChatUtilService] clearStaleTypingIndicators: START - currentUserId: $currentUserId, receiverId: $receiverId');
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      // Get the chat room document
      final doc = await _firestore.collection('chat_rooms').doc(chatRoomId).get();
      
      if (!doc.exists) {
        debugPrint('[ChatUtilService] clearStaleTypingIndicators: room does not exist');
        debugPrint('[ChatUtilService] clearStaleTypingIndicators: END');
        return;
      }
      
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) {
        debugPrint('[ChatUtilService] clearStaleTypingIndicators: no data');
        debugPrint('[ChatUtilService] clearStaleTypingIndicators: END');
        return;
      }
      
      // Check if receiver's typing field is true and has a timestamp
      final typingField = 'typing_$receiverId';
      final lastTypingTimeField = 'typingTimestamp_$receiverId';
      
      final isTyping = data[typingField] as bool? ?? false;
      final lastTypingTime = data[lastTypingTimeField] as Timestamp?;
      
      // If typing is true but no timestamp or timestamp is older than 30 seconds, clear it
      if (isTyping) {
        bool shouldClear = false;
        
        if (lastTypingTime == null) {
          // No timestamp - might be old format, clear it
          shouldClear = true;
          debugPrint('[ChatUtilService] clearStaleTypingIndicators: no timestamp found, clearing');
        } else {
          final age = DateTime.now().difference(lastTypingTime.toDate());
          if (age.inSeconds > 30) {
            shouldClear = true;
            debugPrint('[ChatUtilService] clearStaleTypingIndicators: typing is ${age.inSeconds}s old, clearing');
          }
        }
        
        if (shouldClear) {
          await _firestore.collection('chat_rooms').doc(chatRoomId).update({
            typingField: false,
          });
          debugPrint('[ChatUtilService] clearStaleTypingIndicators: cleared stale typing indicator');
        } else {
          debugPrint('[ChatUtilService] clearStaleTypingIndicators: typing is recent, keeping');
        }
      } else {
        debugPrint('[ChatUtilService] clearStaleTypingIndicators: receiver not typing');
      }
    } catch (e) {
      debugPrint('[ChatUtilService] clearStaleTypingIndicators: ERROR - ${e.runtimeType}: $e');
      // Silently ignore — this is a safety measure, not critical
    }
    debugPrint('[ChatUtilService] clearStaleTypingIndicators: END');
  }

  static Future<void> updateLastSeenTimestamp(
    String currentUserId,
    String receiverId,
  ) async {
    debugPrint('[ChatUtilService] updateLastSeenTimestamp: START - currentUserId: $currentUserId, receiverId: $receiverId');
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      await _firestore.collection('chat_rooms').doc(chatRoomId).update({
        'lastSeen_$currentUserId': FieldValue.serverTimestamp(),
      });
      debugPrint('[ChatUtilService] updateLastSeenTimestamp: SUCCESS - timestamp updated');
    } catch (e) {
      debugPrint('[ChatUtilService] updateLastSeenTimestamp: ERROR - ${e.runtimeType}: $e');
      // Silently ignore — lastSeen is non-critical
    }
    debugPrint('[ChatUtilService] updateLastSeenTimestamp: END');
  }

  // ==========================================================================
  // NOTIFICATIONS
  // ==========================================================================

  static Future<void> sendNotification(
    String receiverId,
    String notificationPreview, {
    String? senderName,
    bool? isMuted,
  }) async {
    debugPrint('[ChatUtilService] sendNotification: START - receiverId: $receiverId, senderName: $senderName, isMuted: $isMuted');
    if (AppConfig.cfWorkerUrl.isEmpty) {
      debugPrint('╔══════════════════════════════════════════════════════════════════╗');
      debugPrint('║ CRITICAL: CF_WORKER_URL not configured                           ║');
      debugPrint('║                                                                  ║');
      debugPrint('║ Push notifications are DISABLED. To enable:                        ║');
      debugPrint('║ 1. Deploy the Cloudflare Worker (separate repository)            ║');
      debugPrint('║ 2. Build with: --dart-define=CF_WORKER_URL=<your-worker-url>     ║');
      debugPrint('║                                                                  ║');
      debugPrint('║ Current build: CF_WORKER_URL="${AppConfig.cfWorkerUrl}"        ║');
      debugPrint('╚══════════════════════════════════════════════════════════════════╝');
      
      debugPrint('[ChatUtilService] sendNotification: WARNING - Notification not sent to $receiverId');
      debugPrint('[ChatUtilService] sendNotification: Skipped preview: "$notificationPreview"');
      debugPrint('[ChatUtilService] sendNotification: END');
      return;
    }

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      debugPrint('[ChatUtilService] sendNotification: ERROR - no current user');
      debugPrint('[ChatUtilService] sendNotification: END');
      return;
    }
    final currentUserId = currentUser.uid;
    final roomId = getRoomId(currentUserId, receiverId);

    try {
      // Use cached mute state if provided, otherwise check Firestore (fallback)
      if (isMuted == true) {
        debugPrint('[ChatUtilService] sendNotification: notification skipped - chat muted (cached)');
        debugPrint('[ChatUtilService] sendNotification: END');
        return;
      }

      if (isMuted == null) {
        debugPrint('[ChatUtilService] sendNotification: checking mute status from Firestore');
        try {
          final chatDoc = await _firestore
              .collection('chat_rooms')
              .doc(roomId)
              .get();
          if (chatDoc.exists) {
            if ((chatDoc.data() ?? {})['muted_$receiverId'] ?? false) {
              debugPrint('[ChatUtilService] sendNotification: notification skipped - chat muted (fallback)');
              debugPrint('[ChatUtilService] sendNotification: END');
              return;
            }
          }
          debugPrint('[ChatUtilService] sendNotification: chat not muted');
        } catch (e) {
          debugPrint('[ChatUtilService] sendNotification: non-critical fallback error - ${e.runtimeType}: $e');
          // Non-critical fallback
        }
      }

      final receiverDoc = await _firestore
          .collection('users')
          .doc(receiverId)
          .get();
      final receiverData = receiverDoc.data();

      if (receiverData == null) {
        debugPrint('[ChatUtilService] sendNotification: ERROR - receiver document missing');
        debugPrint('[ChatUtilService] sendNotification: END');
        return;
      }

      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) {
        debugPrint('[ChatUtilService] sendNotification: ERROR - could not obtain Firebase ID token');
        debugPrint('[ChatUtilService] sendNotification: END');
        return;
      }

      final resolvedSenderName = senderName ?? 'Someone';

      final payload = {
        'receiverId': receiverId,
        'message': notificationPreview,
        'senderName': resolvedSenderName,
        'senderToken': token,
        'senderId': currentUserId,
        'chatRoomId': roomId,
      };

      debugPrint('[ChatUtilService] sendNotification: sending notification to receiverId: $receiverId');

      final response = await http.post(
        Uri.parse(AppConfig.cfWorkerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[ChatUtilService] sendNotification: ERROR - HTTP ${response.statusCode}');
        debugPrint('[ChatUtilService] sendNotification: response body: ${response.body}');
      } else {
        debugPrint('[ChatUtilService] sendNotification: SUCCESS - HTTP ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      debugPrint('[ChatUtilService] sendNotification: ERROR - ${e.runtimeType}: $e');
      if (kDebugMode) {
        debugPrint('[ChatUtilService] sendNotification error: $e');
        debugPrint('[ChatUtilService] $stackTrace');
      }
    }
    debugPrint('[ChatUtilService] sendNotification: END');
  }

  /// Check if push notifications are properly configured
  static Map<String, dynamic> checkNotificationConfig() {
    final config = <String, dynamic>{
      'cfWorkerUrlConfigured': AppConfig.cfWorkerUrl.isNotEmpty,
      'cfWorkerUrlLength': AppConfig.cfWorkerUrl.length,
      'oneSignalConfigured': AppConfig.oneSignalAppId.isNotEmpty,
      'isValid': AppConfig.isValid,
    };
    
    if (AppConfig.cfWorkerUrl.isEmpty) {
      config['error'] = 'CF_WORKER_URL not set. Push notifications disabled.';
      config['hint'] = 'Build with: --dart-define=CF_WORKER_URL=<your-worker-url>';
    } else if (AppConfig.oneSignalAppId.isEmpty) {
      config['error'] = 'ONESIGNAL_APP_ID not set. Push notifications disabled.';
      config['hint'] = 'Build with: --dart-define=ONESIGNAL_APP_ID=<your-app-id>';
    } else {
      config['status'] = 'Push notifications configured';
    }
    
    return config;
  }

  // ==========================================================================
  // MESSAGE DELETION
  // ==========================================================================

  static const _deleteForEveryoneLimit = Duration(minutes: 10);

  static bool canDeleteForEveryone(Map<String, dynamic> data, String userId) {
    debugPrint('[ChatUtilService] canDeleteForEveryone: START - userId: $userId');
    if (data['senderId'] != userId) {
      debugPrint('[ChatUtilService] canDeleteForEveryone: false - not the sender');
      debugPrint('[ChatUtilService] canDeleteForEveryone: END');
      return false;
    }
    final timestamp = data['timestamp'] as Timestamp?;
    if (timestamp == null) {
      debugPrint('[ChatUtilService] canDeleteForEveryone: false - no timestamp');
      debugPrint('[ChatUtilService] canDeleteForEveryone: END');
      return false;
    }
    final age = DateTime.now().difference(timestamp.toDate());
    final canDelete = age <= _deleteForEveryoneLimit;
    debugPrint('[ChatUtilService] canDeleteForEveryone: $canDelete - age: ${age.inMinutes} minutes');
    debugPrint('[ChatUtilService] canDeleteForEveryone: END');
    return canDelete;
  }

  static Future<void> deleteForMe({
    required String chatRoomId,
    required String messageId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] deleteForMe: START - chatRoomId: $chatRoomId, messageId: $messageId, userId: $userId');
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({
            'deletedFor': FieldValue.arrayUnion([userId]),
          });
      debugPrint('[ChatUtilService] deleteForMe: SUCCESS - message marked as deleted for me');
    } catch (e) {
      debugPrint('[ChatUtilService] deleteForMe: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] deleteForMe: END');
  }

  static Future<void> deleteForEveryone({
    required String chatRoomId,
    required String messageId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] deleteForEveryone: START - chatRoomId: $chatRoomId, messageId: $messageId, userId: $userId');
    try {
      final ref = _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId);
      final snap = await ref.get();
      if (!snap.exists) {
        debugPrint('[ChatUtilService] deleteForEveryone: ERROR - message does not exist');
        debugPrint('[ChatUtilService] deleteForEveryone: END');
        return;
      }
      final data = snap.data()!;
      if (!canDeleteForEveryone(data, userId)) {
        debugPrint('[ChatUtilService] deleteForEveryone: ERROR - cannot delete: not sender or time limit exceeded');
        throw Exception('Cannot delete: not sender or time limit exceeded');
      }
      await ref.delete();
      debugPrint('[ChatUtilService] deleteForEveryone: SUCCESS - message deleted for everyone');
    } catch (e) {
      debugPrint('[ChatUtilService] deleteForEveryone: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] deleteForEveryone: END');
  }

  static Future<void> deleteMessages({
    required String chatRoomId,
    required List<DocumentSnapshot> messages,
    required String currentUserId,
    required bool forEveryone,
  }) async {
    debugPrint('[ChatUtilService] deleteMessages: START - chatRoomId: $chatRoomId, messageCount: ${messages.length}, forEveryone: $forEveryone');
    try {
      final batch = _firestore.batch();

      for (final doc in messages) {
        final data = doc.data() as Map<String, dynamic>;
        final isSender = data['senderId'] == currentUserId;

        if (forEveryone &&
            isSender &&
            canDeleteForEveryone(data, currentUserId)) {
          batch.delete(doc.reference);
          debugPrint('[ChatUtilService] deleteMessages: deleting message ${doc.id} for everyone');
        } else {
          batch.update(doc.reference, {
            'deletedFor': FieldValue.arrayUnion([currentUserId]),
          });
          debugPrint('[ChatUtilService] deleteMessages: deleting message ${doc.id} for me');
        }
      }

      await batch.commit();
      debugPrint('[ChatUtilService] deleteMessages: SUCCESS - batch commit completed');
    } catch (e) {
      debugPrint('[ChatUtilService] deleteMessages: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] deleteMessages: END');
  }

  static Future<void> deleteMessageForMe({
    required String chatRoomId,
    required String messageId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] deleteMessageForMe: START - chatRoomId: $chatRoomId, messageId: $messageId');
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedFor': FieldValue.arrayUnion([userId]),
      });
      debugPrint('[ChatUtilService] deleteMessageForMe: SUCCESS');
    } catch (e) {
      debugPrint('[ChatUtilService] deleteMessageForMe: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] deleteMessageForMe: END');
  }

  static Future<void> deleteMessageForEveryone({
    required String chatRoomId,
    required String messageId,
  }) async {
    debugPrint('[ChatUtilService] deleteMessageForEveryone: START - chatRoomId: $chatRoomId, messageId: $messageId');
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .delete();
      debugPrint('[ChatUtilService] deleteMessageForEveryone: SUCCESS');
    } catch (e) {
      debugPrint('[ChatUtilService] deleteMessageForEveryone: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] deleteMessageForEveryone: END');
  }

  // ==========================================================================
  // STARS
  // ==========================================================================

  static Future<void> toggleMessageStar({
    required String chatRoomId,
    required String messageId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] toggleMessageStar: START - chatRoomId: $chatRoomId, messageId: $messageId');
    try {
      final docRef = _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId);
      
      final doc = await docRef.get();
      if (!doc.exists) {
        debugPrint('[ChatUtilService] toggleMessageStar: ERROR - message not found');
        return;
      }
      
      final data = doc.data() as Map<String, dynamic>;
      final starredBy = List<String>.from(data['starredBy'] ?? []);
      final isStarred = starredBy.contains(userId);
      
      if (isStarred) {
        await docRef.update({
          'starredBy': FieldValue.arrayRemove([userId]),
          'starred': false,
        });
        debugPrint('[ChatUtilService] toggleMessageStar: Unstarred');
      } else {
        await docRef.update({
          'starredBy': FieldValue.arrayUnion([userId]),
          'starred': true,
        });
        debugPrint('[ChatUtilService] toggleMessageStar: Starred');
      }
    } catch (e) {
      debugPrint('[ChatUtilService] toggleMessageStar: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] toggleMessageStar: END');
  }

  static Future<void> toggleStarMessage({
    required String chatRoomId,
    required String messageId,
    required bool starred,
  }) async {
    debugPrint('[ChatUtilService] toggleStarMessage: START - chatRoomId: $chatRoomId, messageId: $messageId, starred: $starred');
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({'starred': starred});
      debugPrint('[ChatUtilService] toggleStarMessage: SUCCESS - starred set to $starred');
    } catch (e) {
      debugPrint('[ChatUtilService] toggleStarMessage: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] toggleStarMessage: END');
  }

  static Stream<QuerySnapshot> getStarredMessages(String chatRoomId) {
    debugPrint('[ChatUtilService] getStarredMessages: START - chatRoomId: $chatRoomId');
    final stream = _firestore
        .collection('chat_rooms')
        .doc(chatRoomId)
        .collection('messages')
        .where('starred', isEqualTo: true)
        .snapshots();
    debugPrint('[ChatUtilService] getStarredMessages: returning stream');
    debugPrint('[ChatUtilService] getStarredMessages: END');
    return stream;
  }

  // ==========================================================================
  // DELIVERY & SEEN STATES
  // ==========================================================================

  /// In-memory cache to reduce Firestore reads
  static final Map<String, DateTime> _lastSeenUpdate = {};
  static final Map<String, DateTime> _lastDeliveredUpdate = {};
  static const _minUpdateInterval = Duration(seconds: 2);

  /// Marks messages as seen with rate limiting and batching
  static Future<void> markMessagesAsSeen(
    String currentUserId,
    String receiverId,
  ) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    final cacheKey = '${currentUserId}_$receiverId';
    
    // RATE LIMITING: Skip if updated recently
    final lastUpdate = _lastSeenUpdate[cacheKey];
    if (lastUpdate != null && 
        DateTime.now().difference(lastUpdate) < _minUpdateInterval) {
      return;
    }
    
    debugPrint('[ChatUtilService] markMessagesAsSeen: START - currentUserId: $currentUserId, receiverId: $receiverId');
    
    try {
      // Use limit(50) to prevent large queries
      final snapshot = await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .where('receiverId', isEqualTo: currentUserId)
          .where('status', whereIn: ['sent', 'delivered'])
          .limit(50)
          .get();

      if (snapshot.docs.isEmpty) {
        debugPrint('[ChatUtilService] markMessagesAsSeen: no messages to mark');
        _lastSeenUpdate[cacheKey] = DateTime.now();
        debugPrint('[ChatUtilService] markMessagesAsSeen: END');
        return;
      }

      // Batch updates with server timestamp
      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        final data = doc.data();
        // Skip already seen (idempotent)
        if (data['status'] != 'seen') {
          batch.update(doc.reference, {
            'status': 'seen',
            'seenAt': FieldValue.serverTimestamp(),
          });
        }
      }
      await batch.commit();
      
      _lastSeenUpdate[cacheKey] = DateTime.now();
      debugPrint('[ChatUtilService] markMessagesAsSeen: SUCCESS - ${snapshot.docs.length} messages marked');
    } catch (e) {
      debugPrint('[ChatUtilService] markMessagesAsSeen: ERROR - ${e.runtimeType}: $e');
      // Don't throw - delivery states are non-critical
    }
    debugPrint('[ChatUtilService] markMessagesAsSeen: END');
  }

  /// Marks messages as delivered with rate limiting and batching
  static Future<void> markMessagesAsDelivered(
    String currentUserId,
    String receiverId,
  ) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    final cacheKey = '${currentUserId}_$receiverId';
    
    // RATE LIMITING
    final lastUpdate = _lastDeliveredUpdate[cacheKey];
    if (lastUpdate != null && 
        DateTime.now().difference(lastUpdate) < _minUpdateInterval) {
      return;
    }
    
    debugPrint('[ChatUtilService] markMessagesAsDelivered: START - currentUserId: $currentUserId, receiverId: $receiverId');
    
    try {
      final snapshot = await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .where('receiverId', isEqualTo: currentUserId)
          .where('status', isEqualTo: 'sent')
          .limit(50)
          .get();

      if (snapshot.docs.isEmpty) {
        debugPrint('[ChatUtilService] markMessagesAsDelivered: no messages to mark');
        _lastDeliveredUpdate[cacheKey] = DateTime.now();
        debugPrint('[ChatUtilService] markMessagesAsDelivered: END');
        return;
      }

      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        final data = doc.data();
        // Skip already delivered/seen (idempotent)
        if (data['status'] == 'sent') {
          batch.update(doc.reference, {
            'status': 'delivered',
            'deliveredAt': FieldValue.serverTimestamp(),
          });
        }
      }
      await batch.commit();
      
      _lastDeliveredUpdate[cacheKey] = DateTime.now();
      debugPrint('[ChatUtilService] markMessagesAsDelivered: SUCCESS - ${snapshot.docs.length} messages marked');
    } catch (e) {
      debugPrint('[ChatUtilService] markMessagesAsDelivered: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[ChatUtilService] markMessagesAsDelivered: END');
  }

  static Future<void> markAllMessagesDeliveredBatched(
    String currentUserId,
    List<String> receiverIds,
  ) async {
    debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: START - currentUserId: $currentUserId, receiverCount: ${receiverIds.length}');
    if (receiverIds.isEmpty) {
      debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: no receivers, skipping');
      debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: END');
      return;
    }

    try {
      final batch = _firestore.batch();
      int messageCount = 0;

      for (final receiverId in receiverIds) {
        final chatRoomId = getRoomId(currentUserId, receiverId);
        debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: processing receiver: $receiverId');
        final snapshot = await _firestore
            .collection('chat_rooms')
            .doc(chatRoomId)
            .collection('messages')
            .where('receiverId', isEqualTo: currentUserId)
            .where('status', isEqualTo: 'sent')
            .limit(50)
            .get();

        for (final doc in snapshot.docs) {
          batch.update(doc.reference, {'status': 'delivered'});
          messageCount++;
          if (messageCount >= 500) {
            debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: batch limit reached (500), committing');
            await batch.commit();
            debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: SUCCESS - batch committed');
            debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: END');
            return;
          }
        }
      }

      if (messageCount > 0) {
        await batch.commit();
        debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: SUCCESS - $messageCount messages marked as delivered');
      } else {
        debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: no messages to mark');
      }
    } catch (e) {
      debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: ERROR - ${e.runtimeType}: $e');
      // Silently ignore
    }
    debugPrint('[ChatUtilService] markAllMessagesDeliveredBatched: END');
  }

  /// Clears delivery/seen caches (call on logout)
  static void clearDeliveryCaches() {
    _lastSeenUpdate.clear();
    _lastDeliveredUpdate.clear();
    debugPrint('[ChatUtilService] clearDeliveryCaches: cleared');
  }

  // ==========================================================================
  // MUTE
  // ==========================================================================

  static Future<void> toggleMute({
    required String currentUserId,
    required String receiverId,
    required bool mute,
  }) async {
    debugPrint('[ChatUtilService] toggleMute: START - currentUserId: $currentUserId, receiverId: $receiverId, mute: $mute');
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      await _firestore.collection('chat_rooms').doc(chatRoomId).update({
        'muted_$currentUserId': mute,
      });
      debugPrint('[ChatUtilService] toggleMute: SUCCESS - mute status set to $mute');
    } catch (e) {
      debugPrint('[ChatUtilService] toggleMute: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[ChatUtilService] toggleMute: END');
  }

  static Future<bool> isChatMuted({
    required String currentUserId,
    required String receiverId,
  }) async {
    debugPrint('[ChatUtilService] isChatMuted: START - currentUserId: $currentUserId, receiverId: $receiverId');
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      final doc = await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .get();
      final data = doc.data();
      if (data == null) {
        debugPrint('[ChatUtilService] isChatMuted: chat not found, returning false');
        debugPrint('[ChatUtilService] isChatMuted: END');
        return false;
      }
      final isMuted = data['muted_$currentUserId'] ?? false;
      debugPrint('[ChatUtilService] isChatMuted: SUCCESS - isMuted: $isMuted');
      debugPrint('[ChatUtilService] isChatMuted: END');
      return isMuted;
    } catch (e) {
      debugPrint('[ChatUtilService] isChatMuted: ERROR - ${e.runtimeType}: $e, returning false');
      debugPrint('[ChatUtilService] isChatMuted: END');
      return false;
    }
  }

  // ==========================================================================
  // USER BLOCKING
  // ==========================================================================

  static Future<void> blockUser({
    required String currentUserId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] blockUser: START - currentUserId: $currentUserId, userId: $userId');
    try {
      await _firestore.collection('users').doc(currentUserId).set({
        'blockedUsers': FieldValue.arrayUnion([userId]),
      }, SetOptions(merge: true));
      debugPrint('[ChatUtilService] blockUser: SUCCESS - user blocked');
    } catch (e) {
      debugPrint('[ChatUtilService] blockUser: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] blockUser: END');
  }

  static Future<void> unblockUser({
    required String currentUserId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] unblockUser: START - currentUserId: $currentUserId, userId: $userId');
    try {
      await _firestore.collection('users').doc(currentUserId).update({
        'blockedUsers': FieldValue.arrayRemove([userId]),
      });
      debugPrint('[ChatUtilService] unblockUser: SUCCESS - user unblocked');
    } catch (e) {
      debugPrint('[ChatUtilService] unblockUser: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] unblockUser: END');
  }

  static Future<bool> isUserBlocked({
    required String currentUserId,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] isUserBlocked: START - currentUserId: $currentUserId, userId: $userId');
    try {
      final doc = await _firestore.collection('users').doc(currentUserId).get();
      final data = doc.data();
      if (data == null) {
        debugPrint('[ChatUtilService] isUserBlocked: user document not found, returning false');
        debugPrint('[ChatUtilService] isUserBlocked: END');
        return false;
      }
      final blockedUsers = List<String>.from(data['blockedUsers'] ?? []);
      final isBlocked = blockedUsers.contains(userId);
      debugPrint('[ChatUtilService] isUserBlocked: SUCCESS - isBlocked: $isBlocked');
      debugPrint('[ChatUtilService] isUserBlocked: END');
      return isBlocked;
    } catch (e) {
      debugPrint('[ChatUtilService] isUserBlocked: ERROR - ${e.runtimeType}: $e, returning false');
      debugPrint('[ChatUtilService] isUserBlocked: END');
      return false;
    }
  }

  // ==========================================================================
  // CLEAR CHAT
  // ==========================================================================

  static Future<void> clearChat({
    required String chatRoomId,
    required String currentUserId,
  }) async {
    debugPrint('[ChatUtilService] clearChat: START - chatRoomId: $chatRoomId, currentUserId: $currentUserId');
    try {
      QuerySnapshot snapshot;
      int batchCount = 0;
      do {
        debugPrint('[ChatUtilService] clearChat: fetching batch ${batchCount + 1}');
        snapshot = await _firestore
            .collection('chat_rooms')
            .doc(chatRoomId)
            .collection('messages')
            .limit(500)
            .get();

        if (snapshot.docs.isEmpty) {
          debugPrint('[ChatUtilService] clearChat: no more messages to clear');
          break;
        }

        debugPrint('[ChatUtilService] clearChat: processing ${snapshot.docs.length} messages');
        final batch = _firestore.batch();
        for (final doc in snapshot.docs) {
          batch.update(doc.reference, {
            'deletedFor': FieldValue.arrayUnion([currentUserId]),
          });
        }
        await batch.commit();
        debugPrint('[ChatUtilService] clearChat: batch ${batchCount + 1} committed');
        batchCount++;
      } while (snapshot.docs.length == 500);
      debugPrint('[ChatUtilService] clearChat: SUCCESS - chat cleared, $batchCount batches processed');
    } catch (e) {
      debugPrint('[ChatUtilService] clearChat: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] clearChat: END');
  }

  // ==========================================================================
  // EDIT MESSAGE
  // ==========================================================================

  /// Edits a sent message. Stores encrypted new text and marks as edited.
  static Future<void> editMessage({
    required String chatRoomId,
    required String messageId,
    required String newEncryptedText,
    required String newAesKeyForReceiver,
    required String newAesKeyForSender,
    required String newIv,
    required String originalEncryptedText,
  }) async {
    debugPrint('[ChatUtilService] editMessage: START - chatRoomId: $chatRoomId, messageId: $messageId');
    try {
      await _firestore
          .collection('chat_rooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(messageId)
          .update({
            'text': newEncryptedText,
            'aesKey': newAesKeyForReceiver,
            'aesKeySender': newAesKeyForSender,
            'iv': newIv,
            'editedAt': FieldValue.serverTimestamp(),
            'originalText': originalEncryptedText,
          });
      debugPrint('[ChatUtilService] editMessage: SUCCESS - message edited');
    } catch (e) {
      debugPrint('[ChatUtilService] editMessage: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[ChatUtilService] editMessage: END');
  }

  // ==========================================================================
  // REACTIONS
  // ==========================================================================

  /// Local cache for optimistic reaction updates
  static final Map<String, Map<String, dynamic>> _optimisticReactions = {};

  /// Toggles an emoji reaction with optimistic updates
  static Future<void> toggleReaction({
    required String chatRoomId,
    required String messageId,
    required String emoji,
    required String userId,
  }) async {
    debugPrint('[ChatUtilService] toggleReaction: START - chatRoomId: $chatRoomId, messageId: $messageId, emoji: $emoji, userId: $userId');
    
    final cacheKey = '${chatRoomId}_$messageId';
    final ref = _firestore
        .collection('chat_rooms')
        .doc(chatRoomId)
        .collection('messages')
        .doc(messageId);

    // OPTIMISTIC UPDATE: Apply locally first for immediate UI feedback
    final optimisticKey = '${cacheKey}_$emoji';
    final wasAdded = _applyOptimisticReaction(cacheKey, emoji, userId);
    debugPrint('[ChatUtilService] toggleReaction: optimistic update applied - wasAdded: $wasAdded');

    try {
      // Atomic transaction with retry
      await _runReactionTransaction(ref, emoji, userId, maxRetries: 3);
      
      // Clear optimistic cache on success
      _optimisticReactions.remove(optimisticKey);
      debugPrint('[ChatUtilService] toggleReaction: SUCCESS - sync complete');
    } catch (e) {
      debugPrint('[ChatUtilService] toggleReaction: ERROR - ${e.runtimeType}: $e');
      
      // REVERT optimistic update on failure
      _revertOptimisticReaction(cacheKey, emoji, userId, wasAdded);
      rethrow;
    }
    debugPrint('[ChatUtilService] toggleReaction: END');
  }

  /// Applies optimistic reaction update locally
  static bool _applyOptimisticReaction(String cacheKey, String emoji, String userId) {
    if (!_optimisticReactions.containsKey(cacheKey)) {
      _optimisticReactions[cacheKey] = {};
    }
    
    final reactions = _optimisticReactions[cacheKey]!;
    final users = List<String>.from(reactions[emoji] ?? []);
    final wasAdded = !users.contains(userId);
    
    if (wasAdded) {
      users.add(userId);
    } else {
      users.remove(userId);
    }
    
    if (users.isEmpty) {
      reactions.remove(emoji);
    } else {
      reactions[emoji] = users;
    }
    
    return wasAdded;
  }

  /// Reverts optimistic reaction update on failure
  static void _revertOptimisticReaction(String cacheKey, String emoji, String userId, bool wasAdded) {
    final reactions = _optimisticReactions[cacheKey];
    if (reactions == null) return;
    
    final users = List<String>.from(reactions[emoji] ?? []);
    
    if (wasAdded) {
      users.remove(userId);
    } else {
      users.add(userId);
    }
    
    if (users.isEmpty) {
      reactions.remove(emoji);
    } else {
      reactions[emoji] = users;
    }
  }

  /// Runs atomic reaction transaction with retry logic
  static Future<void> _runReactionTransaction(
    DocumentReference ref,
    String emoji,
    String userId, {
    required int maxRetries,
  }) async {
    int attempts = 0;
    
    while (attempts < maxRetries) {
      try {
        await _firestore.runTransaction((tx) async {
          final snap = await tx.get(ref);
          if (!snap.exists) return;
          
          final data = snap.data() as Map<String, dynamic>?;
          final reactions = Map<String, dynamic>.from(
            (data?['reactions'] as Map<String, dynamic>?) ?? {},
          );
          final users = List<String>.from(reactions[emoji] ?? []);
          
          // CONFLICT RESOLUTION: Use server state as source of truth
          if (users.contains(userId)) {
            users.remove(userId);
          } else {
            users.add(userId);
          }
          
          if (users.isEmpty) {
            reactions.remove(emoji);
          } else {
            reactions[emoji] = users;
          }
          
          tx.update(ref, {'reactions': reactions});
        });
        return; // Success
      } catch (e) {
        attempts++;
        if (attempts >= maxRetries) rethrow;
        
        // Exponential backoff: 100ms, 200ms, 400ms
        await Future.delayed(Duration(milliseconds: 100 * (1 << (attempts - 1))));
      }
    }
  }

  /// Gets reactions with optimistic merge
  static Map<String, dynamic> getReactionsWithOptimistic(
    String chatRoomId,
    String messageId,
    Map<String, dynamic> serverReactions,
  ) {
    final cacheKey = '${chatRoomId}_$messageId';
    final optimistic = _optimisticReactions[cacheKey];
    
    if (optimistic == null) return serverReactions;
    
    // Merge server state with optimistic updates
    final merged = Map<String, dynamic>.from(serverReactions);
    optimistic.forEach((emoji, users) {
      if ((users as List).isEmpty) {
        merged.remove(emoji);
      } else {
        merged[emoji] = users;
      }
    });
    
    return merged;
  }

  /// Gets the optimistic reactions cache (for UI consumption)
  static Map<String, Map<String, dynamic>> get optimisticReactions => 
      Map.unmodifiable(_optimisticReactions);

  /// Clears optimistic reaction cache (call on chat screen exit)
  static void clearOptimisticReactions() {
    _optimisticReactions.clear();
    debugPrint('[ChatUtilService] clearOptimisticReactions: cleared');
  }
}

// ============================================================================
// DATA CLASSES
// ============================================================================

class PublicKeyResult {
  final RSAPublicKey publicKey;
  final String version;

  const PublicKeyResult({required this.publicKey, required this.version});
}

// ============================================================================
// OFFLINE MESSAGE QUEUE
// ============================================================================

/// Lightweight offline message queue backed by FlutterSecureStorage.
class OfflineMessageQueue {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'offline_msg_';

  static Future<void> enqueue(Map<String, dynamic> payload) async {
    debugPrint('[OfflineMessageQueue] enqueue: START');
    try {
      final key = '$_prefix${DateTime.now().microsecondsSinceEpoch}';
      await _storage.write(key: key, value: jsonEncode(payload));
      debugPrint('[OfflineMessageQueue] enqueue: SUCCESS - message enqueued with key: $key');
    } catch (e) {
      debugPrint('[OfflineMessageQueue] enqueue: ERROR - ${e.runtimeType}: $e');
      rethrow;
    }
    debugPrint('[OfflineMessageQueue] enqueue: END');
  }

  static Future<List<MapEntry<String, Map<String, dynamic>>>>
  dequeueAll() async {
    debugPrint('[OfflineMessageQueue] dequeueAll: START');
    try {
      final all = await _storage.readAll();
      final entries = <MapEntry<String, Map<String, dynamic>>>[];
      for (final e in all.entries) {
        if (e.key.startsWith(_prefix)) {
          try {
            entries.add(
              MapEntry(e.key, jsonDecode(e.value) as Map<String, dynamic>),
            );
          } catch (err) {
            debugPrint('[OfflineMessageQueue] dequeueAll: WARNING - failed to decode entry ${e.key}: $err');
          }
        }
      }
      entries.sort((a, b) => a.key.compareTo(b.key)); // FIFO
      debugPrint('[OfflineMessageQueue] dequeueAll: SUCCESS - ${entries.length} messages dequeued');
      debugPrint('[OfflineMessageQueue] dequeueAll: END');
      return entries;
    } catch (e) {
      debugPrint('[OfflineMessageQueue] dequeueAll: ERROR - ${e.runtimeType}: $e');
      debugPrint('[OfflineMessageQueue] dequeueAll: END');
      return [];
    }
  }

  static Future<void> remove(String key) async {
    debugPrint('[OfflineMessageQueue] remove: START - key: $key');
    try {
      await _storage.delete(key: key);
      debugPrint('[OfflineMessageQueue] remove: SUCCESS - message removed');
    } catch (e) {
      debugPrint('[OfflineMessageQueue] remove: ERROR - ${e.runtimeType}: $e');
    }
    debugPrint('[OfflineMessageQueue] remove: END');
  }

  static Future<bool> hasQueued() async {
    debugPrint('[OfflineMessageQueue] hasQueued: START');
    try {
      final all = await _storage.readAll();
      final hasQueued = all.keys.any((k) => k.startsWith(_prefix));
      debugPrint('[OfflineMessageQueue] hasQueued: SUCCESS - hasQueued: $hasQueued');
      debugPrint('[OfflineMessageQueue] hasQueued: END');
      return hasQueued;
    } catch (e) {
      debugPrint('[OfflineMessageQueue] hasQueued: ERROR - ${e.runtimeType}: $e, returning false');
      debugPrint('[OfflineMessageQueue] hasQueued: END');
      return false;
    }
  }
}
