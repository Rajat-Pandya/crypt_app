// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_cache.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class UserCacheAdapter extends TypeAdapter<UserCache> {
  @override
  final int typeId = 0;

  @override
  UserCache read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return UserCache()
      ..uid = fields[0] as String
      ..name = fields[1] as String?
      ..email = fields[2] as String?
      ..isOnline = fields[3] as bool?
      ..lastSeen = fields[4] as DateTime?
      ..oneSignalPlayerId = fields[5] as String?
      ..publicKeyN = fields[6] as String?
      ..publicKeyE = fields[7] as String?
      ..publicKeyVersion = fields[8] as String?
      ..cachedAt = fields[9] as DateTime
      ..syncedAt = fields[10] as DateTime?;
  }

  @override
  void write(BinaryWriter writer, UserCache obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.uid)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.email)
      ..writeByte(3)
      ..write(obj.isOnline)
      ..writeByte(4)
      ..write(obj.lastSeen)
      ..writeByte(5)
      ..write(obj.oneSignalPlayerId)
      ..writeByte(6)
      ..write(obj.publicKeyN)
      ..writeByte(7)
      ..write(obj.publicKeyE)
      ..writeByte(8)
      ..write(obj.publicKeyVersion)
      ..writeByte(9)
      ..write(obj.cachedAt)
      ..writeByte(10)
      ..write(obj.syncedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserCacheAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
