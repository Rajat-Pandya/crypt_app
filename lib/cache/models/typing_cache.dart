import 'package:hive/hive.dart';

part 'typing_cache.g.dart';

@HiveType(typeId: 4)
class TypingStatusCache extends HiveObject {
  @HiveField(0)
  late String roomId;

  @HiveField(1)
  Map<String, bool> typingUsers = {};

  @HiveField(2)
  DateTime cachedAt = DateTime.now();

  bool isTyping(String userId) => typingUsers[userId] ?? false;
}
