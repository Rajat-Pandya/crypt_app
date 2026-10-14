import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

part 'message_cache.g.dart';

// ============================================================================
// ENUMS
// ============================================================================

/// Message decryption states
@HiveType(typeId: 20)
enum MessageDecryptState {
  @HiveField(0)
  pending,      // Decryption in progress
  @HiveField(1)
  success,      // Successfully decrypted
  @HiveField(2)
  failed,       // Decryption failed
  @HiveField(3)
  keyError,     // Missing or invalid key
  @HiveField(4)
  corrupted,    // Data corruption detected
}

/// Message delivery states
@HiveType(typeId: 21)
enum MessageDeliveryState {
  @HiveField(0)
  sending,      // Optimistic: message being sent
  @HiveField(1)
  sent,         // Message sent to server
  @HiveField(2)
  delivered,    // Message delivered to recipient
  @HiveField(3)
  seen,         // Message seen by recipient
  @HiveField(4)
  failed,       // Send failed
}

// ============================================================================
// MESSAGE REACTION MODEL
// ============================================================================

/// Typed reaction model with safe parsing
/// 
/// Legacy schema compatibility: Can parse from both:
/// - New: Map<String, List<String>> with full metadata
/// - Legacy: Map<String, dynamic> from Firestore
@HiveType(typeId: 22)
class MessageReaction extends HiveObject {
  @HiveField(0)
  late String emoji;

  @HiveField(1)
  late List<String> userIds;

  @HiveField(2)
  DateTime? reactedAt;

  @HiveField(3)
  String? reactedBy; // Legacy compatibility

  MessageReaction({
    required this.emoji,
    required this.userIds,
    this.reactedAt,
    this.reactedBy,
  });

  /// Safe parsing from Firestore Map with legacy compatibility
  /// 
  /// Handles both:
  /// - New: {"emoji": "👍", "userIds": ["uid1", "uid2"], "reactedAt": Timestamp}
  /// - Legacy: {"👍": ["uid1", "uid2"]} (flat emoji -> users map)
  static Map<String, MessageReaction> parseReactions(dynamic data) {
    if (data == null) return {};
    
    final reactions = <String, MessageReaction>{};
    
    if (data is Map<String, dynamic>) {
      data.forEach((key, value) {
        // Try to parse as new format first
        if (value is Map<String, dynamic>) {
          final userIds = _parseStringList(value['userIds']);
          if (userIds.isNotEmpty) {
            reactions[key] = MessageReaction(
              emoji: key,
              userIds: userIds,
              reactedAt: _parseTimestamp(value['reactedAt']),
              reactedBy: value['reactedBy'] as String?,
            );
          }
        } 
        // Legacy format: emoji -> List<dynamic>
        else if (value is List) {
          final userIds = _parseStringList(value);
          if (userIds.isNotEmpty) {
            reactions[key] = MessageReaction(
              emoji: key,
              userIds: userIds,
              reactedAt: DateTime.now(),
            );
          }
        }
      });
    }
    
    return reactions;
  }

  /// Converts reactions to Firestore-compatible Map
  /// 
  /// Uses legacy-compatible format: {"emoji": ["uid1", "uid2"]}
  Map<String, dynamic> toFirestore() {
    return {
      emoji: userIds,
    };
  }

  /// Converts to cache-friendly Map
  Map<String, dynamic> toCache() {
    return {
      'emoji': emoji,
      'userIds': userIds,
      'reactedAt': reactedAt?.millisecondsSinceEpoch,
      'reactedBy': reactedBy,
    };
  }

  /// Checks if a user has reacted with this emoji
  bool hasUser(String userId) => userIds.contains(userId);

  /// Total reaction count
  int get count => userIds.length;

  /// Safe string list parsing with null-safety
  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value
          .map((e) => e?.toString())
          .where((s) => s != null && s.isNotEmpty)
          .cast<String>()
          .toList();
    }
    return [];
  }

  /// Safe timestamp parsing with null-safety
  static DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is DateTime) return value;
    return null;
  }
}

// ============================================================================
// MESSAGE CACHE MODEL
// ============================================================================

@HiveType(typeId: 2)
class MessageCache extends HiveObject {
  // Core fields
  @HiveField(0)
  late String roomId;

  @HiveField(1)
  late String messageId;

  @HiveField(2)
  late String senderId;

  @HiveField(3)
  late String receiverId;

  // Encryption fields
  @HiveField(4)
  late String encryptedText;

  @HiveField(5)
  late String encryptedAesKey;

  @HiveField(6)
  String? encryptedAesKeySender;

  @HiveField(7)
  late String iv;

  // Key versioning
  @HiveField(8)
  String? senderKeyVersion;

  @HiveField(9)
  String? receiverKeyVersion;

  // Legacy status field (kept for compatibility)
  @HiveField(10)
  String? status;

  @HiveField(11)
  DateTime? timestamp;

  @HiveField(12)
  bool? starred;

  @HiveField(13)
  List<String> deletedFor = [];

  // Legacy reactions format (kept for schema migration)
  @HiveField(14)
  Map<String, List<String>> reactions = {};

  // Cache metadata
  @HiveField(15)
  DateTime cachedAt = DateTime.now();

  @HiveField(16)
  DateTime? syncedAt;

  // NEW FIELDS (schema v2)
  @HiveField(17)
  MessageDecryptState? decryptState;

  @HiveField(18)
  String? decryptedText;

  @HiveField(19)
  MessageDeliveryState? deliveryState;

  @HiveField(20)
  String? replyToMessageId;

  @HiveField(21)
  String? replyPreview;

  @HiveField(22)
  DateTime? deliveredAt;

  @HiveField(23)
  DateTime? seenAt;

  @HiveField(24)
  bool? isOptimistic;

  @HiveField(25)
  bool? hasMedia; // FEATURE 4: Flag for media attachments

  @HiveField(26)
  String? messageType; // text/image/file/audio - UNENCRYPTED for quick access

  // ==========================================================================
  // COMPUTED PROPERTIES
  // ==========================================================================

  bool get isDeletedForMe => deletedFor.isNotEmpty;

  /// Get delivery state with fallback to legacy status field
  MessageDeliveryState get effectiveDeliveryState {
    if (deliveryState != null) return deliveryState!;
    
    // Legacy compatibility
    switch (status) {
      case 'sending':
        return MessageDeliveryState.sending;
      case 'sent':
        return MessageDeliveryState.sent;
      case 'delivered':
        return MessageDeliveryState.delivered;
      case 'seen':
        return MessageDeliveryState.seen;
      case 'failed':
        return MessageDeliveryState.failed;
      default:
        return MessageDeliveryState.sent;
    }
  }

  /// Get decrypt state with fallback
  MessageDecryptState get effectiveDecryptState {
    return decryptState ?? MessageDecryptState.pending;
  }

  /// Check if message is decrypted
  bool get isDecrypted => 
      decryptState == MessageDecryptState.success && decryptedText != null;

  /// Check if message is from current user
  bool isFromMe(String currentUserId) => senderId == currentUserId;

  // ==========================================================================
  // LEGACY COMPATIBILITY
  // ==========================================================================

  /// Converts legacy Map<String, List<String>> reactions to typed format
  Map<String, MessageReaction> get typedReactions {
    final result = <String, MessageReaction>{};
    reactions.forEach((emoji, userIds) {
      result[emoji] = MessageReaction(
        emoji: emoji,
        userIds: userIds,
        reactedAt: timestamp,
      );
    });
    return result;
  }

  /// Sets reactions from typed format (backwards compatible)
  set typedReactions(Map<String, MessageReaction> value) {
    reactions = value.map((key, reaction) => 
      MapEntry(key, reaction.userIds));
  }

  // ==========================================================================
  // FACTORY METHODS
  // ==========================================================================

  /// Safe factory from Firestore DocumentSnapshot
  /// 
  /// Handles null-safety, legacy fields, and type coercion
  static MessageCache? fromFirestore(DocumentSnapshot doc) {
    try {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return null;

      return MessageCache()
        ..messageId = doc.id
        ..senderId = _safeString(data['senderId'])
        ..receiverId = _safeString(data['receiverId'])
        ..encryptedText = _safeString(data['text'])
        ..encryptedAesKey = _safeString(data['aesKey'])
        ..encryptedAesKeySender = data['aesKeySender'] as String?
        ..iv = _safeString(data['iv'])
        ..senderKeyVersion = data['senderKeyVersion'] as String?
        ..receiverKeyVersion = data['receiverKeyVersion'] as String?
        ..status = data['status'] as String?
        ..timestamp = _safeTimestamp(data['timestamp'])
        ..starred = data['starred'] as bool? ?? false
        ..deletedFor = _safeStringList(data['deletedFor'])
        ..reactions = _safeReactionsMap(data['reactions'])
        ..deliveryState = _parseDeliveryState(data['status'])
        ..deliveredAt = _safeTimestamp(data['deliveredAt'])
        ..seenAt = _safeTimestamp(data['seenAt'])
        ..replyToMessageId = data['replyToMessageId'] as String?
        ..replyPreview = data['replyPreview'] as String?
        ..messageType = data['messageType'] as String? ?? 'text'
        ..syncedAt = DateTime.now();
    } catch (e) {
      print('[MessageCache] Error parsing from Firestore: $e');
      return null;
    }
  }

  /// Creates copy with updated fields
  MessageCache copyWith({
    String? roomId,
    String? messageId,
    String? senderId,
    String? receiverId,
    String? encryptedText,
    String? encryptedAesKey,
    String? encryptedAesKeySender,
    String? iv,
    String? senderKeyVersion,
    String? receiverKeyVersion,
    String? status,
    DateTime? timestamp,
    bool? starred,
    List<String>? deletedFor,
    Map<String, List<String>>? reactions,
    MessageDecryptState? decryptState,
    String? decryptedText,
    MessageDeliveryState? deliveryState,
    String? replyToMessageId,
    String? replyPreview,
    DateTime? deliveredAt,
    DateTime? seenAt,
    bool? isOptimistic,
    bool? hasMedia,
    String? messageType,
  }) {
    final copy = MessageCache()
      ..roomId = roomId ?? this.roomId
      ..messageId = messageId ?? this.messageId
      ..senderId = senderId ?? this.senderId
      ..receiverId = receiverId ?? this.receiverId
      ..encryptedText = encryptedText ?? this.encryptedText
      ..encryptedAesKey = encryptedAesKey ?? this.encryptedAesKey
      ..encryptedAesKeySender = encryptedAesKeySender ?? this.encryptedAesKeySender
      ..iv = iv ?? this.iv
      ..senderKeyVersion = senderKeyVersion ?? this.senderKeyVersion
      ..receiverKeyVersion = receiverKeyVersion ?? this.receiverKeyVersion
      ..status = status ?? this.status
      ..timestamp = timestamp ?? this.timestamp
      ..starred = starred ?? this.starred
      ..deletedFor = deletedFor ?? this.deletedFor
      ..reactions = reactions ?? this.reactions
      ..cachedAt = cachedAt
      ..syncedAt = DateTime.now()
      ..decryptState = decryptState ?? this.decryptState
      ..decryptedText = decryptedText ?? this.decryptedText
      ..deliveryState = deliveryState ?? this.deliveryState
      ..replyToMessageId = replyToMessageId ?? this.replyToMessageId
      ..replyPreview = replyPreview ?? this.replyPreview
      ..deliveredAt = deliveredAt ?? this.deliveredAt
      ..seenAt = seenAt ?? this.seenAt
      ..isOptimistic = isOptimistic ?? this.isOptimistic
      ..hasMedia = hasMedia ?? this.hasMedia
      ..messageType = messageType ?? this.messageType;
    
    return copy;
  }

  // ==========================================================================
  // SAFE PARSING HELPERS
  // ==========================================================================

  static String _safeString(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;
    if (value is String) return value;
    return value.toString();
  }

  static List<String> _safeStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value
          .map((e) => e?.toString())
          .where((s) => s != null && s.isNotEmpty)
          .cast<String>()
          .toList();
    }
    return [];
  }

  static DateTime? _safeTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is DateTime) return value;
    return null;
  }

  static Map<String, List<String>> _safeReactionsMap(dynamic value) {
    if (value == null) return {};
    if (value is! Map) return {};
    
    final result = <String, List<String>>{};
    value.forEach((key, val) {
      if (key is String && val is List) {
        final userIds = val
            .map((e) => e?.toString())
            .where((s) => s != null && s.isNotEmpty)
            .cast<String>()
            .toList();
        if (userIds.isNotEmpty) {
          result[key] = userIds;
        }
      }
    });
    return result;
  }

  static MessageDeliveryState? _parseDeliveryState(dynamic value) {
    if (value == null) return null;
    final str = value.toString().toLowerCase();
    switch (str) {
      case 'sending':
        return MessageDeliveryState.sending;
      case 'sent':
        return MessageDeliveryState.sent;
      case 'delivered':
        return MessageDeliveryState.delivered;
      case 'seen':
        return MessageDeliveryState.seen;
      case 'failed':
        return MessageDeliveryState.failed;
      default:
        return null;
    }
  }

  static MessageDecryptState? _parseDecryptState(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      if (value >= 0 && value < MessageDecryptState.values.length) {
        return MessageDecryptState.values[value];
      }
    }
    final str = value.toString().toLowerCase();
    switch (str) {
      case 'pending':
        return MessageDecryptState.pending;
      case 'success':
        return MessageDecryptState.success;
      case 'failed':
        return MessageDecryptState.failed;
      case 'keyerror':
      case 'key_error':
        return MessageDecryptState.keyError;
      case 'corrupted':
        return MessageDecryptState.corrupted;
      default:
        return null;
    }
  }

  // ==========================================================================
  // JSON SERIALIZATION
  // ==========================================================================

  /// Converts to JSON for network transfer
  Map<String, dynamic> toJson() {
    return {
      'roomId': roomId,
      'messageId': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
      'encryptedText': encryptedText,
      'encryptedAesKey': encryptedAesKey,
      'encryptedAesKeySender': encryptedAesKeySender,
      'iv': iv,
      'senderKeyVersion': senderKeyVersion,
      'receiverKeyVersion': receiverKeyVersion,
      'status': status,
      'timestamp': timestamp?.millisecondsSinceEpoch,
      'starred': starred,
      'deletedFor': deletedFor,
      'reactions': reactions,
      'cachedAt': cachedAt.millisecondsSinceEpoch,
      'syncedAt': syncedAt?.millisecondsSinceEpoch,
      'decryptState': decryptState?.index,
      'decryptedText': decryptedText,
      'deliveryState': deliveryState?.index,
      'replyToMessageId': replyToMessageId,
      'replyPreview': replyPreview,
      'deliveredAt': deliveredAt?.millisecondsSinceEpoch,
      'seenAt': seenAt?.millisecondsSinceEpoch,
      'isOptimistic': isOptimistic,
      'hasMedia': hasMedia,
      'messageType': messageType,
    };
  }

  /// Creates from JSON with safe parsing
  static MessageCache? fromJson(Map<String, dynamic> json) {
    try {
      return MessageCache()
        ..roomId = _safeString(json['roomId'])
        ..messageId = _safeString(json['messageId'])
        ..senderId = _safeString(json['senderId'])
        ..receiverId = _safeString(json['receiverId'])
        ..encryptedText = _safeString(json['encryptedText'])
        ..encryptedAesKey = _safeString(json['encryptedAesKey'])
        ..encryptedAesKeySender = json['encryptedAesKeySender'] as String?
        ..iv = _safeString(json['iv'])
        ..senderKeyVersion = json['senderKeyVersion'] as String?
        ..receiverKeyVersion = json['receiverKeyVersion'] as String?
        ..status = json['status'] as String?
        ..timestamp = _safeTimestamp(json['timestamp'])
        ..starred = json['starred'] as bool? ?? false
        ..deletedFor = _safeStringList(json['deletedFor'])
        ..reactions = _safeReactionsMap(json['reactions'])
        ..cachedAt = _safeTimestamp(json['cachedAt']) ?? DateTime.now()
        ..syncedAt = _safeTimestamp(json['syncedAt'])
        ..decryptState = _parseDecryptState(json['decryptState'])
        ..decryptedText = json['decryptedText'] as String?
        ..deliveryState = json['deliveryState'] != null 
            ? MessageDeliveryState.values[json['deliveryState'] as int]
            : null
        ..replyToMessageId = json['replyToMessageId'] as String?
        ..replyPreview = json['replyPreview'] as String?
        ..deliveredAt = _safeTimestamp(json['deliveredAt'])
        ..seenAt = _safeTimestamp(json['seenAt'])
        ..isOptimistic = json['isOptimistic'] as bool?
        ..hasMedia = json['hasMedia'] as bool?
        ..messageType = json['messageType'] as String? ?? 'text';
    } catch (e) {
      print('[MessageCache] Error parsing from JSON: $e');
      return null;
    }
  }
}
