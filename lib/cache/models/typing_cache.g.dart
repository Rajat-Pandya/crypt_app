// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'typing_cache.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TypingStatusCacheAdapter extends TypeAdapter<TypingStatusCache> {
  @override
  final int typeId = 4;

  @override
  TypingStatusCache read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TypingStatusCache()
      ..roomId = fields[0] as String
      ..typingUsers = (fields[1] as Map).cast<String, bool>()
      ..cachedAt = fields[2] as DateTime;
  }

  @override
  void write(BinaryWriter writer, TypingStatusCache obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.roomId)
      ..writeByte(1)
      ..write(obj.typingUsers)
      ..writeByte(2)
      ..write(obj.cachedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TypingStatusCacheAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
