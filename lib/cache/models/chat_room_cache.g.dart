// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_room_cache.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ChatRoomCacheAdapter extends TypeAdapter<ChatRoomCache> {
  @override
  final int typeId = 1;

  @override
  ChatRoomCache read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChatRoomCache()
      ..roomId = fields[0] as String
      ..users = (fields[1] as List).cast<String>()
      ..lastMessage = fields[2] as String?
      ..lastMessageTime = fields[3] as DateTime?
      ..pinnedByCurrentUser = fields[4] as bool?
      ..mutedBy = (fields[5] as Map).cast<String, bool>()
      ..cachedAt = fields[6] as DateTime
      ..syncedAt = fields[7] as DateTime?;
  }

  @override
  void write(BinaryWriter writer, ChatRoomCache obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.roomId)
      ..writeByte(1)
      ..write(obj.users)
      ..writeByte(2)
      ..write(obj.lastMessage)
      ..writeByte(3)
      ..write(obj.lastMessageTime)
      ..writeByte(4)
      ..write(obj.pinnedByCurrentUser)
      ..writeByte(5)
      ..write(obj.mutedBy)
      ..writeByte(6)
      ..write(obj.cachedAt)
      ..writeByte(7)
      ..write(obj.syncedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatRoomCacheAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
