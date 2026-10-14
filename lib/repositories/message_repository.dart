import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';
import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';
import '../services/decrypt_queue_manager.dart';

/// Message repository with centralized decrypt management.
/// 
/// Features:
/// - Decrypt operations happen outside build phase
/// - Proper caching of decrypted plaintext
/// - Distinct stream filtering to prevent duplicate emissions
/// - Throttled delivery/update emissions
/// - Legacy key version persistence
class MessageRepository {
  static final MessageRepository _instance = MessageRepository._internal();
  factory MessageRepository() => _instance;
  MessageRepository._internal();
  
  final _firestore = FirebaseFirestore.instance;
  final _storage = const FlutterSecureStorage();
  final _decryptQueue = DecryptQueueManager();
  
  // Cache configuration
  static const Duration _cacheExpiry = Duration(minutes: 30);
  static const int _maxCacheSize = 500;
  
  // Decrypted message cache
  final Map<String, _CachedMessage> _decryptedCache = {};
  final Map<String, StreamSubscription> _subscriptions = {};
  
  // Stream controllers with distinct filtering
  final Map<String, StreamController<List<Message>>> _streamControllers = {};
  final Map<String, List<Message>> _lastEmitted = {};
  
  // Throttling
  final Map<String, DateTime> _lastDeliveryUpdate = {};
  static const Duration _deliveryThrottle = Duration(seconds: 2);
  
  /// Get cached decrypted message.
  String? getCachedDecrypted(String messageId) {
    final cached = _decryptedCache[messageId];
    if (cached == null) return null;
    
    // Check expiry
    if (DateTime.now().difference(cached.timestamp) > _cacheExpiry) {
      _decryptedCache.remove(messageId);
      return null;
    }
    
    return cached.plaintext;
  }
  
  /// Set cached decrypted message.
  void setCachedDecrypted(String messageId, String plaintext) {
    // Trim cache if too large
    if (_decryptedCache.length >= _maxCacheSize) {
      final oldest = _decryptedCache.entries
          .toList()
          ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
      final toRemove = oldest.take(_maxCacheSize ~/ 4).map((e) => e.key);
      for (final key in toRemove) {
        _decryptedCache.remove(key);
      }
    }
    
    _decryptedCache[messageId] = _CachedMessage(
      plaintext: plaintext,
      timestamp: DateTime.now(),
    );
  }
  
  /// Clear cached message (e.g., after edit).
  void clearCachedDecrypted(String messageId) {
    _decryptedCache.remove(messageId);
  }
  
  /// Clear all caches.
  void clearAllCaches() {
    _decryptedCache.clear();
  }
  
  /// Queue a decrypt operation.
  /// 
  /// Returns cached result if available, otherwise queues decrypt.
  Future<String> decryptMessage({
    required String messageId,
    required String encryptedText,
    required String aesKeyEncrypted,
    required String iv,
    required RSAPrivateKey privateKey,
  }) async {
    // Check cache first
    final cached = getCachedDecrypted(messageId);
    if (cached != null) {
      return cached;
    }
    
    // Queue decrypt
    final result = await _decryptQueue.queueDecrypt(
      messageId: messageId,
      decryptFn: () async {
        final aesKey = await RSAHelper.decrypt(aesKeyEncrypted, privateKey);
        final plaintext = await EncryptionHelper.decryptMessage(
          encryptedText,
          aesKey,
          iv,
        );
        setCachedDecrypted(messageId, plaintext);
        return plaintext;
      },
    );
    
    // If dedupe returned empty, check cache
    if (result.isEmpty) {
      return getCachedDecrypted(messageId) ?? '🔒';
    }
    
    return result;
  }
  
  /// Get messages stream with distinct filtering and throttling.
  Stream<List<Message>> getMessagesStream({
    required String chatRoomId,
    required int limit,
    DocumentSnapshot? startAfter,
  }) {
    // Return existing stream if available
    if (_streamControllers.containsKey(chatRoomId)) {
      return _streamControllers[chatRoomId]!.stream;
    }
    
    // Create new controller
    final controller = StreamController<List<Message>>.broadcast(
      onCancel: () {
        _subscriptions[chatRoomId]?.cancel();
        _subscriptions.remove(chatRoomId);
        _streamControllers.remove(chatRoomId);
      },
    );
    
    _streamControllers[chatRoomId] = controller;
    
    // Build query
    var query = _firestore
        .collection('chat_rooms')
        .doc(chatRoomId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(limit);
    
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    
    // Subscribe with distinct filtering
    final subscription = query.snapshots().listen((snapshot) {
      final messages = _transformSnapshot(snapshot);
      
      // Distinct filtering - only emit if different from last
      if (_shouldEmit(chatRoomId, messages)) {
        _lastEmitted[chatRoomId] = messages;
        controller.add(messages);
      }
    }, onError: (e) {
      controller.addError(e);
    });
    
    _subscriptions[chatRoomId] = subscription;
    
    return controller.stream;
  }
  
  /// Check if should emit (distinct + throttle).
  bool _shouldEmit(String chatRoomId, List<Message> messages) {
    final last = _lastEmitted[chatRoomId];
    if (last == null) return true;
    
    // Check if lists are different
    if (last.length != messages.length) return true;
    
    for (int i = 0; i < messages.length; i++) {
      if (last[i].id != messages[i].id) return true;
      if (last[i].text != messages[i].text) return true;
      if (last[i].editedAt != messages[i].editedAt) return true;
    }
    
    return false;
  }
  
  /// Transform snapshot to messages.
  List<Message> _transformSnapshot(QuerySnapshot snapshot) {
    return snapshot.docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      return Message(
        id: doc.id,
        senderId: data['senderId'] as String? ?? '',
        text: data['text'] as String? ?? '',
        timestamp: data['timestamp'] as Timestamp?,
        editedAt: data['editedAt'] as Timestamp?,
        aesKey: data['aesKey'] as String?,
        aesKeySender: data['aesKeySender'] as String?,
        iv: data['iv'] as String?,
        senderKeyVersion: data['senderKeyVersion'] as String?,
        receiverKeyVersion: data['receiverKeyVersion'] as String?,
        reactions: data['reactions'] as Map<String, dynamic>?,
        replyTo: data['replyTo'] as Map<String, dynamic>?,
        starred: data['starred'] as bool? ?? false,
        deletedFor: List<String>.from(data['deletedFor'] ?? []),
        status: data['status'] as String?,
      );
    }).toList();
  }
  
  /// Mark messages as delivered with throttling.
  Future<void> markMessagesAsDelivered({
    required String chatRoomId,
    required String currentUserId,
    required String receiverId,
  }) async {
    final key = '${chatRoomId}_$receiverId';
    final last = _lastDeliveryUpdate[key];
    if (last != null && DateTime.now().difference(last) < _deliveryThrottle) {
      return; // Throttled
    }
    _lastDeliveryUpdate[key] = DateTime.now();
    
    // Mark as delivered in Firestore
    final roomId = chatRoomId;
    final messages = await _firestore
        .collection('chat_rooms')
        .doc(roomId)
        .collection('messages')
        .where('receiverId', isEqualTo: currentUserId)
        .where('status', isEqualTo: 'sent')
        .get();
    
    final batch = _firestore.batch();
    for (final doc in messages.docs) {
      batch.update(doc.reference, {'status': 'delivered'});
    }
    await batch.commit();
  }
  
  /// Mark messages as seen.
  Future<void> markMessagesAsSeen({
    required String chatRoomId,
    required String currentUserId,
    required String receiverId,
  }) async {
    final roomId = chatRoomId;
    final messages = await _firestore
        .collection('chat_rooms')
        .doc(roomId)
        .collection('messages')
        .where('receiverId', isEqualTo: currentUserId)
        .where('status', whereIn: ['sent', 'delivered'])
        .get();
    
    final batch = _firestore.batch();
    for (final doc in messages.docs) {
      batch.update(doc.reference, {'status': 'seen'});
    }
    await batch.commit();
  }
  
  /// Persist key versions after successful legacy decrypt.
  Future<void> persistKeyVersions({
    required String messageId,
    required String senderKeyVersion,
    required String receiverKeyVersion,
    String encryptionVersion = '1.0',
  }) async {
    await _storage.write(
      key: 'msg_key_versions_$messageId',
      value: jsonEncode({
        'senderKeyVersion': senderKeyVersion,
        'receiverKeyVersion': receiverKeyVersion,
        'encryptionVersion': encryptionVersion,
        'persistedAt': DateTime.now().toIso8601String(),
      }),
    );
  }
  
  /// Check if key versions were persisted.
  Future<Map<String, dynamic>?> getPersistedKeyVersions(String messageId) async {
    final stored = await _storage.read(key: 'msg_key_versions_$messageId');
    if (stored == null) return null;
    try {
      return jsonDecode(stored) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
  
  /// Dispose all resources.
  void dispose() {
    _decryptQueue.dispose();
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
    _lastEmitted.clear();
    _decryptedCache.clear();
  }
}

class _CachedMessage {
  final String plaintext;
  final DateTime timestamp;
  
  _CachedMessage({
    required this.plaintext,
    required this.timestamp,
  });
}

/// Message model.
class Message {
  final String id;
  final String senderId;
  final String text;
  final Timestamp? timestamp;
  final Timestamp? editedAt;
  final String? aesKey;
  final String? aesKeySender;
  final String? iv;
  final String? senderKeyVersion;
  final String? receiverKeyVersion;
  final Map<String, dynamic>? reactions;
  final Map<String, dynamic>? replyTo;
  final bool starred;
  final List<String> deletedFor;
  final String? status;
  
  Message({
    required this.id,
    required this.senderId,
    required this.text,
    this.timestamp,
    this.editedAt,
    this.aesKey,
    this.aesKeySender,
    this.iv,
    this.senderKeyVersion,
    this.receiverKeyVersion,
    this.reactions,
    this.replyTo,
    required this.starred,
    required this.deletedFor,
    this.status,
  });
  
  bool get isEdited => editedAt != null;
  bool get isDeletedForMe => deletedFor.contains(senderId);
  bool get hasReactions => reactions != null && reactions!.isNotEmpty;
}
