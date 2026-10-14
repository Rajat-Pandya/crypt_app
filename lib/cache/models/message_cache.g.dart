// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message_cache.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MessageReactionAdapter extends TypeAdapter<MessageReaction> {
  @override
  final int typeId = 22;

  @override
  MessageReaction read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MessageReaction(
      emoji: fields[0] as String,
      userIds: (fields[1] as List).cast<String>(),
      reactedAt: fields[2] as DateTime?,
      reactedBy: fields[3] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, MessageReaction obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.emoji)
      ..writeByte(1)
      ..write(obj.userIds)
      ..writeByte(2)
      ..write(obj.reactedAt)
      ..writeByte(3)
      ..write(obj.reactedBy);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageReactionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MessageCacheAdapter extends TypeAdapter<MessageCache> {
  @override
  final int typeId = 2;

  @override
  MessageCache read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return MessageCache()
      ..roomId = fields[0] as String
      ..messageId = fields[1] as String
      ..senderId = fields[2] as String
      ..receiverId = fields[3] as String
      ..encryptedText = fields[4] as String
      ..encryptedAesKey = fields[5] as String
      ..encryptedAesKeySender = fields[6] as String?
      ..iv = fields[7] as String
      ..senderKeyVersion = fields[8] as String?
      ..receiverKeyVersion = fields[9] as String?
      ..status = fields[10] as String?
      ..timestamp = fields[11] as DateTime?
      ..starred = fields[12] as bool?
      ..deletedFor = (fields[13] as List).cast<String>()
      ..reactions = (fields[14] as Map).map((dynamic k, dynamic v) =>
          MapEntry(k as String, (v as List).cast<String>()))
      ..cachedAt = fields[15] as DateTime
      ..syncedAt = fields[16] as DateTime?
      ..decryptState = fields[17] as MessageDecryptState?
      ..decryptedText = fields[18] as String?
      ..deliveryState = fields[19] as MessageDeliveryState?
      ..replyToMessageId = fields[20] as String?
      ..replyPreview = fields[21] as String?
      ..deliveredAt = fields[22] as DateTime?
      ..seenAt = fields[23] as DateTime?
      ..isOptimistic = fields[24] as bool?;
  }

  @override
  void write(BinaryWriter writer, MessageCache obj) {
    writer
      ..writeByte(25)
      ..writeByte(0)
      ..write(obj.roomId)
      ..writeByte(1)
      ..write(obj.messageId)
      ..writeByte(2)
      ..write(obj.senderId)
      ..writeByte(3)
      ..write(obj.receiverId)
      ..writeByte(4)
      ..write(obj.encryptedText)
      ..writeByte(5)
      ..write(obj.encryptedAesKey)
      ..writeByte(6)
      ..write(obj.encryptedAesKeySender)
      ..writeByte(7)
      ..write(obj.iv)
      ..writeByte(8)
      ..write(obj.senderKeyVersion)
      ..writeByte(9)
      ..write(obj.receiverKeyVersion)
      ..writeByte(10)
      ..write(obj.status)
      ..writeByte(11)
      ..write(obj.timestamp)
      ..writeByte(12)
      ..write(obj.starred)
      ..writeByte(13)
      ..write(obj.deletedFor)
      ..writeByte(14)
      ..write(obj.reactions)
      ..writeByte(15)
      ..write(obj.cachedAt)
      ..writeByte(16)
      ..write(obj.syncedAt)
      ..writeByte(17)
      ..write(obj.decryptState)
      ..writeByte(18)
      ..write(obj.decryptedText)
      ..writeByte(19)
      ..write(obj.deliveryState)
      ..writeByte(20)
      ..write(obj.replyToMessageId)
      ..writeByte(21)
      ..write(obj.replyPreview)
      ..writeByte(22)
      ..write(obj.deliveredAt)
      ..writeByte(23)
      ..write(obj.seenAt)
      ..writeByte(24)
      ..write(obj.isOptimistic);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageCacheAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MessageDecryptStateAdapter extends TypeAdapter<MessageDecryptState> {
  @override
  final int typeId = 20;

  @override
  MessageDecryptState read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MessageDecryptState.pending;
      case 1:
        return MessageDecryptState.success;
      case 2:
        return MessageDecryptState.failed;
      case 3:
        return MessageDecryptState.keyError;
      case 4:
        return MessageDecryptState.corrupted;
      default:
        return MessageDecryptState.pending;
    }
  }

  @override
  void write(BinaryWriter writer, MessageDecryptState obj) {
    switch (obj) {
      case MessageDecryptState.pending:
        writer.writeByte(0);
        break;
      case MessageDecryptState.success:
        writer.writeByte(1);
        break;
      case MessageDecryptState.failed:
        writer.writeByte(2);
        break;
      case MessageDecryptState.keyError:
        writer.writeByte(3);
        break;
      case MessageDecryptState.corrupted:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageDecryptStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MessageDeliveryStateAdapter extends TypeAdapter<MessageDeliveryState> {
  @override
  final int typeId = 21;

  @override
  MessageDeliveryState read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MessageDeliveryState.sending;
      case 1:
        return MessageDeliveryState.sent;
      case 2:
        return MessageDeliveryState.delivered;
      case 3:
        return MessageDeliveryState.seen;
      case 4:
        return MessageDeliveryState.failed;
      default:
        return MessageDeliveryState.sending;
    }
  }

  @override
  void write(BinaryWriter writer, MessageDeliveryState obj) {
    switch (obj) {
      case MessageDeliveryState.sending:
        writer.writeByte(0);
        break;
      case MessageDeliveryState.sent:
        writer.writeByte(1);
        break;
      case MessageDeliveryState.delivered:
        writer.writeByte(2);
        break;
      case MessageDeliveryState.seen:
        writer.writeByte(3);
        break;
      case MessageDeliveryState.failed:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageDeliveryStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
