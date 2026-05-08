import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:http/http.dart' as http;

import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';
import '../utils/input_validator.dart';
import '../config/app_config.dart';

class ChatService {
  static final _firestore = FirebaseFirestore.instance;
  static final _storage = const FlutterSecureStorage();

  static void _dbg(String message) {
    assert(() {
      debugPrint('[ChatService] $message');
      return true;
    }());
  }

  static String getRoomId(String u1, String u2) {
    final users = [u1, u2]..sort();
    return users.join("_");
  }

  static Future<PublicKeyResult?> loadReceiverPublicKey(
    String receiverId, {
    bool forceServer = false,
  }) async {
    try {
      DocumentSnapshot<Map<String, dynamic>> doc;
      if (forceServer) {
        try {
          doc = await _firestore
              .collection("users")
              .doc(receiverId)
              .get(const GetOptions(source: Source.server));
        } on FirebaseException {
          // Offline — fall back to cache rather than returning null
          doc = await _firestore
              .collection("users")
              .doc(receiverId)
              .get(const GetOptions(source: Source.cache));
        }
      } else {
        doc = await _firestore
            .collection("users")
            .doc(receiverId)
            .get(const GetOptions(source: Source.serverAndCache));
      }
      final data = doc.data();

      // User doesn't exist at all
      if (data == null) {
        _dbg('loadReceiverPublicKey: user $receiverId does not exist');
        return null;
      }

      // User exists but no publicKey yet (not fully registered)
      if (data["publicKey"] == null) {
        _dbg('loadReceiverPublicKey: user exists but no public key yet');
        return null;
      }

      final keyData = data["publicKey"] as Map<String, dynamic>;
      final version = data["publicKeyVersion"] as String? ?? 'v1';

      _dbg(
        'loadReceiverPublicKey: loaded key version=$version for $receiverId',
      );

      return PublicKeyResult(
        publicKey: RSAPublicKey(
          BigInt.parse(keyData["n"] as String),
          BigInt.parse(keyData["e"] as String),
        ),
        version: version,
      );
    } catch (e) {
      _dbg('loadReceiverPublicKey: error — ${e.runtimeType}');
      return null;
    }
  }

  static Future<String?> loadPrivateKey() async {
    return await _storage.read(key: "private_key");
  }

  static Future<void> updateTyping(
    String currentUserId,
    String receiverId,
    bool typing,
  ) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      await _firestore.collection("chat_rooms").doc(chatRoomId).update({
        "typing_$currentUserId": typing,
      });
    } catch (_) {
      // Silently ignore — typing is non-critical (room may not exist yet)
    }
  }

  static Future<void> updateLastSeenTimestamp(
    String currentUserId,
    String receiverId,
  ) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      await _firestore.collection("chat_rooms").doc(chatRoomId).update({
        "lastSeen_$currentUserId": FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Silently ignore — lastSeen is non-critical
    }
  }

  /// 🔴 FIX Bug 1 — Notifications were showing "New message" with no sender info
  /// and non-2xx responses were silent.
  ///
  /// Changed:
  ///   • notificationPreview parameter now receives senderName (not "New message")
  ///   • Added HTTP status check — logs failures visibly
  ///   • Payload 'message' field now uses senderName for user visibility
  static Future<void> sendNotification(
    String receiverId,
    String notificationPreview, {
    String? senderName,
  }) async {
    if (AppConfig.cfWorkerUrl.isEmpty) {
      _dbg('CF_WORKER_URL not set — notification skipped');
      return;
    }

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final currentUserId = currentUser.uid;
    final roomId = getRoomId(currentUserId, receiverId);

    try {
      bool isMuted = false;
      try {
        final chatDoc = await _firestore
            .collection("chat_rooms")
            .doc(roomId)
            .get();
        if (chatDoc.exists) {
          isMuted = (chatDoc.data() ?? {})["muted_$receiverId"] ?? false;
        }
      } catch (_) {
        // Non-critical
      }

      if (isMuted) {
        _dbg('notification skipped — chat muted');
        return;
      }

      // ✅ FIX: No need to fetch OneSignal Player ID anymore
      // We're using Firebase UID as external user ID
      final receiverDoc = await _firestore
          .collection("users")
          .doc(receiverId)
          .get();
      final receiverData = receiverDoc.data();

      if (receiverData == null) {
        _dbg('notification skipped — receiver document missing');
        return;
      }

      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) {
        _dbg('notification skipped — could not obtain Firebase ID token');
        return;
      }

      final resolvedSenderName = senderName ?? "Someone";

      // ✅ FIX: Use receiverId (Firebase UID) as external user ID
      final payload = {
        'receiverId': receiverId, // This is the Firebase UID
        'message': notificationPreview,
        'senderName': resolvedSenderName,
        'senderToken': token,
        'senderId': currentUserId,
        'chatRoomId': roomId, // ✅ Added for navigation
      };

      _dbg('Sending notification to receiverId: $receiverId');

      final response = await http.post(
        Uri.parse(AppConfig.cfWorkerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _dbg('notification FAILED: HTTP ${response.statusCode}');
        _dbg('Response body: ${response.body}');
      } else {
        _dbg('notification sent: HTTP ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _dbg('sendNotification: error occurred');
      if (kDebugMode) {
        debugPrint('[ChatService] sendNotification error: $e');
        debugPrint('[ChatService] $stackTrace');
      }
    }
  }

  /// Sends a message with optional replyTo metadata.
  static Future<void> sendMessage({
    required String currentUserId,
    required String receiverId,
    required String text,
    required RSAPublicKey receiverPublicKey,
    required RSAPublicKey senderPublicKey,
    Map<String, dynamic>? replyTo, // {messageId, preview}
  }) async {
    final error = InputValidator.validateMessage(text);
    if (error != null) throw Exception(error);

    final chatRoomId = getRoomId(currentUserId, receiverId);

    final encryptedData = await EncryptionHelper.encryptMessage(text);

    final encryptedAESKeyForReceiver = await RSAHelper.encrypt(
      encryptedData["key"]!,
      receiverPublicKey,
    );
    final encryptedAESKeyForSender = await RSAHelper.encrypt(
      encryptedData["key"]!,
      senderPublicKey,
    );

    await _firestore.collection("chat_rooms").doc(chatRoomId).set({
      "users": [currentUserId, receiverId],
      "lastMessageTime": FieldValue.serverTimestamp(),
      "lastMessage": "🔒 Encrypted message",
    }, SetOptions(merge: true));

    final keyVersionResults = await Future.wait([
      loadReceiverPublicKey(currentUserId),
      loadReceiverPublicKey(receiverId),
    ]);
    final myKeyVersion = keyVersionResults[0]?.version ?? 'v1';
    final receiverKeyVersion = keyVersionResults[1]?.version ?? 'v1';

    await _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .add({
          "senderId": currentUserId,
          "receiverId": receiverId,
          "text": encryptedData["text"],
          "aesKey": encryptedAESKeyForReceiver,
          "aesKeySender": encryptedAESKeyForSender,
          "iv": encryptedData["iv"],
          "senderKeyVersion": myKeyVersion,
          "receiverKeyVersion": receiverKeyVersion,
          "status": "sent",
          "timestamp": FieldValue.serverTimestamp(),
          "starred": false,
          "deletedFor": [],
          "reactions": {},
          if (replyTo != null) "replyTo": replyTo,
        });

    String senderName = "Someone";
    try {
      final senderDoc = await _firestore
          .collection("users")
          .doc(currentUserId)
          .get();
      senderName = (senderDoc.data()?["name"] as String?) ?? "Someone";
    } catch (_) {}

    await sendNotification(receiverId, senderName, senderName: senderName);
  }

  static const _deleteForEveryoneLimit = Duration(minutes: 10);

  static bool canDeleteForEveryone(Map<String, dynamic> data, String userId) {
    if (data["senderId"] != userId) return false;
    final timestamp = data["timestamp"] as Timestamp?;
    if (timestamp == null) return false;
    final age = DateTime.now().difference(timestamp.toDate());
    return age <= _deleteForEveryoneLimit;
  }

  static Future<void> deleteForMe({
    required String chatRoomId,
    required String messageId,
    required String userId,
  }) async {
    await _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .doc(messageId)
        .update({
          "deletedFor": FieldValue.arrayUnion([userId]),
        });
  }

  static Future<void> deleteForEveryone({
    required String chatRoomId,
    required String messageId,
    required String userId,
  }) async {
    final ref = _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .doc(messageId);
    final snap = await ref.get();
    if (!snap.exists) return;
    final data = snap.data()!;
    if (!canDeleteForEveryone(data, userId)) {
      throw Exception("Cannot delete: not sender or time limit exceeded");
    }
    await ref.delete();
  }

  static Future<void> deleteMessages({
    required String chatRoomId,
    required List<DocumentSnapshot> messages,
    required String currentUserId,
    required bool forEveryone,
  }) async {
    final batch = _firestore.batch();

    for (final doc in messages) {
      final data = doc.data() as Map<String, dynamic>;
      final isSender = data["senderId"] == currentUserId;

      if (forEveryone &&
          isSender &&
          canDeleteForEveryone(data, currentUserId)) {
        batch.delete(doc.reference);
      } else {
        batch.update(doc.reference, {
          "deletedFor": FieldValue.arrayUnion([currentUserId]),
        });
      }
    }

    await batch.commit();
  }

  static Future<void> markMessagesAsSeen(
    String currentUserId,
    String receiverId,
  ) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      final snapshot = await _firestore
          .collection("chat_rooms")
          .doc(chatRoomId)
          .collection("messages")
          .where("receiverId", isEqualTo: currentUserId)
          .where("status", whereIn: ["sent", "delivered"])
          .get();

      if (snapshot.docs.isEmpty) return;

      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {"status": "seen"});
      }
      await batch.commit();
    } catch (e) {
      // Silently ignore
    }
  }

  static Future<void> markMessagesAsDelivered(
    String currentUserId,
    String receiverId,
  ) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      final snapshot = await _firestore
          .collection("chat_rooms")
          .doc(chatRoomId)
          .collection("messages")
          .where("receiverId", isEqualTo: currentUserId)
          .where("status", isEqualTo: "sent")
          .get();

      if (snapshot.docs.isEmpty) return;

      final batch = _firestore.batch();
      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {"status": "delivered"});
      }
      await batch.commit();
    } catch (e) {
      // Silently ignore
    }
  }

  static Future<void> toggleMute({
    required String currentUserId,
    required String receiverId,
    required bool mute,
  }) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      await _firestore.collection("chat_rooms").doc(chatRoomId).update({
        "muted_$currentUserId": mute,
      });
    } catch (e) {
      _dbg('toggleMute: error — $e');
    }
  }

  static Future<bool> isChatMuted({
    required String currentUserId,
    required String receiverId,
  }) async {
    final chatRoomId = getRoomId(currentUserId, receiverId);
    try {
      final doc = await _firestore
          .collection("chat_rooms")
          .doc(chatRoomId)
          .get();
      final data = doc.data();
      if (data == null) return false;
      return data["muted_$currentUserId"] ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Edits a sent message. Stores encrypted new text and marks as edited.
  /// Original encrypted text is preserved as [originalText] for audit.
  static Future<void> editMessage({
    required String chatRoomId,
    required String messageId,
    required String newEncryptedText,
    required String newAesKeyForReceiver,
    required String newAesKeyForSender,
    required String newIv,
    required String originalEncryptedText,
  }) async {
    await _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .doc(messageId)
        .update({
          "text": newEncryptedText,
          "aesKey": newAesKeyForReceiver,
          "aesKeySender": newAesKeyForSender,
          "iv": newIv,
          "editedAt": FieldValue.serverTimestamp(),
          "originalText": originalEncryptedText, // encrypted, audit only
        });
  }

  /// Toggles an emoji reaction for [userId] on a message.
  /// Reactions stored as {"👍": ["uid1", "uid2"], ...}
  static Future<void> toggleReaction({
    required String chatRoomId,
    required String messageId,
    required String emoji,
    required String userId,
  }) async {
    final ref = _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .doc(messageId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final reactions = Map<String, dynamic>.from(
        (snap.data()!["reactions"] as Map<String, dynamic>?) ?? {},
      );
      final users = List<String>.from(reactions[emoji] ?? []);
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
      tx.update(ref, {"reactions": reactions});
    });
  }

  static Future<void> toggleStarMessage({
    required String chatRoomId,
    required String messageId,
    required bool starred,
  }) async {
    await _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .doc(messageId)
        .update({"starred": starred});
  }

  static Stream<QuerySnapshot> getStarredMessages(String chatRoomId) {
    return _firestore
        .collection("chat_rooms")
        .doc(chatRoomId)
        .collection("messages")
        .where("starred", isEqualTo: true)
        .snapshots();
  }

  static Future<void> clearChat({
    required String chatRoomId,
    required String currentUserId,
  }) async {
    try {
      QuerySnapshot snapshot;
      do {
        snapshot = await _firestore
            .collection("chat_rooms")
            .doc(chatRoomId)
            .collection("messages")
            .limit(500)
            .get();

        if (snapshot.docs.isEmpty) break;

        final batch = _firestore.batch();
        for (final doc in snapshot.docs) {
          batch.update(doc.reference, {
            "deletedFor": FieldValue.arrayUnion([currentUserId]),
          });
        }
        await batch.commit();
      } while (snapshot.docs.length == 500);
    } catch (e) {
      _dbg('clearChat: error — $e');
      rethrow;
    }
  }

  static Future<void> blockUser({
    required String currentUserId,
    required String userId,
  }) async {
    await _firestore.collection("users").doc(currentUserId).set({
      "blockedUsers": FieldValue.arrayUnion([userId]),
    }, SetOptions(merge: true));
  }

  static Future<void> unblockUser({
    required String currentUserId,
    required String userId,
  }) async {
    await _firestore.collection("users").doc(currentUserId).update({
      "blockedUsers": FieldValue.arrayRemove([userId]),
    });
  }

  static Future<bool> isUserBlocked({
    required String currentUserId,
    required String userId,
  }) async {
    try {
      final doc = await _firestore.collection("users").doc(currentUserId).get();
      final data = doc.data();
      if (data == null) return false;
      final blockedUsers = List<String>.from(data["blockedUsers"] ?? []);
      return blockedUsers.contains(userId);
    } catch (e) {
      return false;
    }
  }
}

class PublicKeyResult {
  final RSAPublicKey publicKey;
  final String version;

  const PublicKeyResult({required this.publicKey, required this.version});
}

/// Lightweight offline message queue backed by FlutterSecureStorage.
/// Each queued item is a JSON-encoded map stored under a unique key.
class OfflineMessageQueue {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'offline_msg_';

  static Future<void> enqueue(Map<String, dynamic> payload) async {
    final key = '$_prefix${DateTime.now().microsecondsSinceEpoch}';
    await _storage.write(key: key, value: jsonEncode(payload));
  }

  static Future<List<MapEntry<String, Map<String, dynamic>>>>
  dequeueAll() async {
    final all = await _storage.readAll();
    final entries = <MapEntry<String, Map<String, dynamic>>>[];
    for (final e in all.entries) {
      if (e.key.startsWith(_prefix)) {
        try {
          entries.add(
            MapEntry(e.key, jsonDecode(e.value) as Map<String, dynamic>),
          );
        } catch (_) {}
      }
    }
    entries.sort((a, b) => a.key.compareTo(b.key)); // FIFO
    return entries;
  }

  static Future<void> remove(String key) async {
    await _storage.delete(key: key);
  }

  static Future<bool> hasQueued() async {
    final all = await _storage.readAll();
    return all.keys.any((k) => k.startsWith(_prefix));
  }
}
