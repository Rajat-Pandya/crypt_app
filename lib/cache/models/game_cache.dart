import 'package:hive/hive.dart';

part 'game_cache.g.dart';

@HiveType(typeId: 3)
class GameCache extends HiveObject {
  @HiveField(0)
  late String roomId;

  @HiveField(1)
  String? gameType;

  @HiveField(2)
  Map<String, dynamic>? gameData;

  @HiveField(3)
  String? status;

  @HiveField(4)
  DateTime cachedAt = DateTime.now();

  @HiveField(5)
  DateTime? syncedAt;
}
