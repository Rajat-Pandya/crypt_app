import 'package:cloud_firestore/cloud_firestore.dart';

/// Immutable UI state for a message bubble.
/// 
/// Used with ValueNotifier for granular rebuilds.
class MessageUIState {
  final String id;
  final String senderId;
  final String plaintext;
  final bool isDecrypted;
  final bool isDecrypting;
  final bool isEdited;
  final DateTime? editedAt;
  final Timestamp? timestamp;
  final Map<String, dynamic>? reactions;
  final Map<String, dynamic>? replyTo;
  final bool isEditing;
  final bool isStarred;
  final List<String> deletedFor;
  final String? status;
  final String? error;
  
  MessageUIState({
    required this.id,
    required this.senderId,
    required this.plaintext,
    required this.isDecrypted,
    this.isDecrypting = false,
    this.isEdited = false,
    this.editedAt,
    this.timestamp,
    this.reactions,
    this.replyTo,
    this.isEditing = false,
    this.isStarred = false,
    this.deletedFor = const [],
    this.status,
    this.error,
  });
  
  /// Initial state for a message.
  factory MessageUIState.initial(String messageId) {
    return MessageUIState(
      id: messageId,
      senderId: '',
      plaintext: '🔒',
      isDecrypted: false,
      isDecrypting: true,
    );
  }
  
  /// Create from Firestore document.
  factory MessageUIState.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MessageUIState(
      id: doc.id,
      senderId: data['senderId'] as String? ?? '',
      plaintext: '🔒', // Will be decrypted
      isDecrypted: false,
      isDecrypting: true,
      isEdited: data['editedAt'] != null,
      editedAt: data['editedAt'] != null 
          ? (data['editedAt'] as Timestamp).toDate() 
          : null,
      timestamp: data['timestamp'] as Timestamp?,
      reactions: data['reactions'] as Map<String, dynamic>?,
      replyTo: data['replyTo'] as Map<String, dynamic>?,
      isStarred: data['starred'] as bool? ?? false,
      deletedFor: List<String>.from(data['deletedFor'] ?? []),
      status: data['status'] as String?,
    );
  }
  
  /// Copy with changes.
  MessageUIState copyWith({
    String? plaintext,
    bool? isDecrypted,
    bool? isDecrypting,
    bool? isEdited,
    DateTime? editedAt,
    Timestamp? timestamp,
    Map<String, dynamic>? reactions,
    Map<String, dynamic>? replyTo,
    bool? isEditing,
    bool? isStarred,
    List<String>? deletedFor,
    String? status,
    String? error,
  }) {
    return MessageUIState(
      id: id,
      senderId: senderId,
      plaintext: plaintext ?? this.plaintext,
      isDecrypted: isDecrypted ?? this.isDecrypted,
      isDecrypting: isDecrypting ?? this.isDecrypting,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
      timestamp: timestamp ?? this.timestamp,
      reactions: reactions ?? this.reactions,
      replyTo: replyTo ?? this.replyTo,
      isEditing: isEditing ?? this.isEditing,
      isStarred: isStarred ?? this.isStarred,
      deletedFor: deletedFor ?? this.deletedFor,
      status: status ?? this.status,
      error: error ?? this.error,
    );
  }
  
  /// Equality for distinct checks.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MessageUIState &&
        other.id == id &&
        other.plaintext == plaintext &&
        other.isDecrypted == isDecrypted &&
        other.isDecrypting == isDecrypting &&
        other.isEdited == isEdited &&
        other.isEditing == isEditing;
  }
  
  @override
  int get hashCode => Object.hash(
    id,
    plaintext,
    isDecrypted,
    isDecrypting,
    isEdited,
    isEditing,
  );
  
  /// Convenience getters
  bool get hasReactions => reactions != null && reactions!.isNotEmpty;
}
