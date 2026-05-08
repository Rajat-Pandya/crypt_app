import 'package:cloud_firestore/cloud_firestore.dart';

class ChatListService {
  static final _firestore = FirebaseFirestore.instance;

  static String getRoomId(String u1, String u2) {
    final users = [u1, u2]..sort();
    return users.join("_");
  }

  /// Streams all chat rooms the current user is a member of,
  /// ordered by most recent message first.
  static Stream<QuerySnapshot> getChatRooms(String currentUserId) {
    assert(currentUserId.isNotEmpty, 'currentUserId must not be empty');

    return _firestore
        .collection("chat_rooms")
        .where("users", arrayContains: currentUserId)
        .orderBy("lastMessageTime", descending: true)
        .snapshots();
  }

  /// Streams messages in [roomId] that arrived after [lastSeen]
  /// and were NOT sent by [currentUserId].
  ///
  /// 🔴 FIX Issue #2 — isOnline defaults to true (caller issue)
  /// When calling getUserStream(), callers should default isOnline to false:
  ///   final isOnline = (userData["isOnline"] as bool?) ?? false;
  /// NOT:
  ///   final isOnline = (userData["isOnline"] as bool?) ?? true;
  ///
  /// Reason: If a user document doesn't have isOnline field yet,
  /// defaulting to true makes them falsely appear online.
  /// Conservative default (false) is safer.
  ///
  /// 🟡 FIX Issue #6 — Online status logic must reconcile two signals
  /// Two signals determine if a user is online:
  ///   1. isOnline field (explicit: user logged in/out)
  ///   2. lastSeen timestamp (implicit: recently active = likely online)
  ///
  /// Proper reconciliation:
  ///   • If isOnline == false → offline (explicit logout/sign-off wins)
  ///   • Else if lastSeen < 20 seconds ago → online (recently active)
  ///   • Else → offline (stale, not recently active)
  ///
  /// Example in chat_list_screen.dart:
  ///   final isOnlineField = (userData["isOnline"] as bool?) ?? false;
  ///   final lastSeenTime = (userData["lastSeen"] as Timestamp?)?.toDate();
  ///
  ///   bool isOnline = false;
  ///   if (isOnlineField) {
  ///     if (lastSeenTime != null) {
  ///       final diff = DateTime.now().difference(lastSeenTime).inSeconds;
  ///       isOnline = diff < 20;
  ///     }
  ///   }
  ///
  /// This ensures explicit logout is respected while active users appear online.
  ///
  /// ── Composite Index Required ───────────────────────────────────────────
  /// This query uses senderId and timestamp filters on different fields.
  /// Firestore requires a composite index:
  ///   Collection: messages
  ///   Fields:     senderId ASC, timestamp ASC
  ///
  /// Add to firestore.indexes.json or create via Firebase console.
  /// If missing, the stream will surface an error via catchError.
  ///
  /// ── deletedFor Filtering ───────────────────────────────────────────────
  /// Firestore has no "array-not-contains" operator.
  /// Messages deleted "for me" are included in this stream.
  /// The caller MUST filter them locally:
  ///
  ///   final visible = snapshot.docs.where((doc) {
  ///     final data = doc.data() as Map<String, dynamic>;
  ///     final deletedFor = List<String>.from(data["deletedFor"] ?? []);
  ///     return !deletedFor.contains(currentUserId);
  ///   });
  ///   final unreadCount = visible.length;
  /// ────────────────────────────────────────────────────────────────────────
  static Stream<QuerySnapshot> getUnreadMessages(
    String roomId,
    Timestamp lastSeen,
    String currentUserId,
  ) {
    assert(roomId.isNotEmpty, 'roomId must not be empty');
    assert(currentUserId.isNotEmpty, 'currentUserId must not be empty');

    return _firestore
        .collection("chat_rooms")
        .doc(roomId)
        .collection("messages")
        .where("timestamp", isGreaterThan: lastSeen)
        .where("senderId", isNotEqualTo: currentUserId)
        .snapshots()
        .handleError((e) {
          throw e;
        });
  }

  /// Streams the user document for [userId].
  /// Used to show name and online status in the chat list tile.
  ///
  /// 🔴 FIX Issue #2 — isOnline field defaults
  /// When reading from this stream, default isOnline to false:
  ///   final isOnline = (userData["isOnline"] as bool?) ?? false;
  ///
  /// See getUnreadMessages() documentation for full online status logic.
  static Stream<DocumentSnapshot> getUserStream(String userId) {
    assert(userId.isNotEmpty, 'userId must not be empty');

    return _firestore.collection("users").doc(userId).snapshots();
  }
}
