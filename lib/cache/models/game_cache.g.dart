// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'game_cache.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class GameCacheAdapter extends TypeAdapter<GameCache> {
  @override
  final int typeId = 3;

  @override
  GameCache read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return GameCache()
      ..roomId = fields[0] as String
      ..gameType = fields[1] as String?
      ..gameData = (fields[2] as Map?)?.cast<String, dynamic>()
      ..status = fields[3] as String?
      ..cachedAt = fields[4] as DateTime
      ..syncedAt = fields[5] as DateTime?;
  }

  @override
  void write(BinaryWriter writer, GameCache obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.roomId)
      ..writeByte(1)
      ..write(obj.gameType)
      ..writeByte(2)
      ..write(obj.gameData)
      ..writeByte(3)
      ..write(obj.status)
      ..writeByte(4)
      ..write(obj.cachedAt)
      ..writeByte(5)
      ..write(obj.syncedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GameCacheAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
