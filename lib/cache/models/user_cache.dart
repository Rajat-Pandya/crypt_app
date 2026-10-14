import 'package:hive/hive.dart';

part 'user_cache.g.dart';

@HiveType(typeId: 0)
class UserCache extends HiveObject {
  @HiveField(0)
  late String uid;

  @HiveField(1)
  String? name;

  @HiveField(2)
  String? email;

  @HiveField(3)
  bool? isOnline;

  @HiveField(4)
  DateTime? lastSeen;

  @HiveField(5)
  String? oneSignalPlayerId;

  @HiveField(6)
  String? publicKeyN;

  @HiveField(7)
  String? publicKeyE;

  @HiveField(8)
  String? publicKeyVersion;

  @HiveField(9)
  DateTime cachedAt = DateTime.now();

  @HiveField(10)
  DateTime? syncedAt;

  // FEATURE 1: Profile photo URL
  @HiveField(11)
  String? photoUrl;

  // FEATURE 2: About / status text
  @HiveField(12)
  String? about;

  // FEATURE 5: Username
  @HiveField(13)
  String? username;

  // FEATURE 3: Last seen privacy
  @HiveField(14)
  String? lastSeenPrivacy; // "everyone" | "contacts" | "nobody"

  // FEATURE 4: Online privacy
  @HiveField(15)
  String? onlinePrivacy; // "everyone" | "nobody"
}
