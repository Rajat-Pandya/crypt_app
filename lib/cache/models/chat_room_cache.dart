import 'package:hive/hive.dart';

part 'chat_room_cache.g.dart';

@HiveType(typeId: 1)
class ChatRoomCache extends HiveObject {
  @HiveField(0)
  late String roomId;

  @HiveField(1)
  late List<String> users;

  @HiveField(2)
  String? lastMessage;

  @HiveField(3)
  DateTime? lastMessageTime;

  @HiveField(4)
  bool? pinnedByCurrentUser;

  @HiveField(5)
  Map<String, bool> mutedBy = {};

  @HiveField(6)
  DateTime cachedAt = DateTime.now();

  @HiveField(7)
  DateTime? syncedAt;

  bool get isPinned => pinnedByCurrentUser ?? false;
}
