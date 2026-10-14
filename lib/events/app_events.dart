import 'dart:async';
import 'package:flutter/foundation.dart';

/// DEPRECATED: EventBus is no longer used in the codebase.
/// 
/// The BLoC pattern provides all necessary event communication through
/// state streams. EventBus created a parallel communication channel
/// that was difficult to trace and test.
/// 
/// Migration: Use BLoC state streams instead of EventBus:
///   // Before (EventBus):
///   EventBus().on<MessageReceivedEvent>().listen((event) { ... });
///   
///   // After (BLoC):
///   BlocProvider.of<ChatBloc>(context).stream.listen((state) { ... });
@Deprecated('Use BLoC state streams instead. EventBus is no longer maintained.')
class EventBus {
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;
  EventBus._internal();

  final Map<Type, StreamController<dynamic>> _controllers = {};
  final Map<Type, Stream<dynamic>> _streams = {};

  /// Listen to events of type T
  Stream<T> on<T>() {
    final type = _getType<T>();
    if (!_controllers.containsKey(type)) {
      _controllers[type] = StreamController<dynamic>.broadcast();
      _streams[type] = _controllers[type]!.stream;
    }
    return _streams[type]!.cast<T>();
  }

  /// Emit an event
  void emit(dynamic event) {
    final type = event.runtimeType;
    if (_controllers.containsKey(type)) {
      _controllers[type]!.add(event);
      _debug('Emitted: $type');
    } else {
      _debug('No listeners for: $type');
    }
  }

  /// Emit once with auto-cleanup (for one-time events)
  void emitOnce(dynamic event) {
    emit(event);
    Future.delayed(const Duration(milliseconds: 100), () {
      // Event delivered, stream remains for future listeners
    });
  }

  /// Dispose all controllers
  void dispose() {
    for (final controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
    _streams.clear();
  }

  Type _getType<T>() {
    // Handle generic types properly
    return T;
  }

  void _debug(String message) {
    assert(() {
      debugPrint('[EventBus] $message');
      return true;
    }());
  }
}

// ─── CORE EVENTS ─────────────────────────────────────────────────────────

/// Base event class for BLoC events
abstract class BlocEvent {
  final DateTime timestamp;
  final String? traceId;
  
  BlocEvent({this.traceId}) : timestamp = DateTime.now();
}

// ─── MESSAGE EVENTS ────────────────────────────────────────────────────────

class MessageReceivedEvent extends BlocEvent {
  final String roomId;
  final String messageId;
  final String senderId;
  
  MessageReceivedEvent({
    required this.roomId,
    required this.messageId,
    required this.senderId,
    super.traceId,
  });
}

class MessageDecryptedEvent extends BlocEvent {
  final String messageId;
  final String decryptedText;
  final bool success;
  final String? error;
  
  MessageDecryptedEvent({
    required this.messageId,
    required this.decryptedText,
    this.success = true,
    this.error,
    super.traceId,
  });
}

class MessageSentEvent extends BlocEvent {
  final String roomId;
  final String messageId;
  final String tempId;
  final bool success;
  final String? error;
  
  MessageSentEvent({
    required this.roomId,
    required this.messageId,
    required this.tempId,
    this.success = true,
    this.error,
    super.traceId,
  });
}

class DeliveryConfirmedEvent extends BlocEvent {
  final String messageId;
  final String status; // 'sent', 'delivered', 'seen'
  
  DeliveryConfirmedEvent({
    required this.messageId,
    required this.status,
    super.traceId,
  });
}

class MessageDeletedEvent extends BlocEvent {
  final String messageId;
  final String roomId;
  final bool forEveryone;
  
  MessageDeletedEvent({
    required this.messageId,
    required this.roomId,
    this.forEveryone = false,
    super.traceId,
  });
}

class MessageEditedEvent extends BlocEvent {
  final String messageId;
  final String newText;
  
  MessageEditedEvent({
    required this.messageId,
    required this.newText,
    super.traceId,
  });
}

class MessageStarredEvent extends BlocEvent {
  final String messageId;
  final bool isStarred;
  
  MessageStarredEvent({
    required this.messageId,
    required this.isStarred,
    super.traceId,
  });
}

// ─── TYPING EVENTS ─────────────────────────────────────────────────────────

class TypingUpdatedEvent extends BlocEvent {
  final String roomId;
  final String userId;
  final bool isTyping;
  
  TypingUpdatedEvent({
    required this.roomId,
    required this.userId,
    required this.isTyping,
    super.traceId,
  });
}

// ─── ENCRYPTION EVENTS ─────────────────────────────────────────────────────

class KeysReadyEvent extends BlocEvent {
  final String roomId;
  final bool success;
  final String? error;
  
  KeysReadyEvent({
    required this.roomId,
    this.success = true,
    this.error,
    super.traceId,
  });
}

class KeyRotatedEvent extends BlocEvent {
  final String userId;
  final String oldVersion;
  final String newVersion;
  
  KeyRotatedEvent({
    required this.userId,
    required this.oldVersion,
    required this.newVersion,
    super.traceId,
  });
}

class EncryptionErrorEvent extends BlocEvent {
  final String operation;
  final String error;
  final String? messageId;
  
  EncryptionErrorEvent({
    required this.operation,
    required this.error,
    this.messageId,
    super.traceId,
  });
}

// ─── CONNECTIVITY EVENTS ─────────────────────────────────────────────────

class ConnectivityChangedEvent extends BlocEvent {
  final bool isOnline;
  final String? networkType; // 'wifi', 'mobile', 'none'
  
  ConnectivityChangedEvent({
    required this.isOnline,
    this.networkType,
    super.traceId,
  });
}

class ReconnectCompleteEvent extends BlocEvent {
  final bool success;
  final int messagesSynced;
  final String? error;
  
  ReconnectCompleteEvent({
    this.success = true,
    this.messagesSynced = 0,
    this.error,
    super.traceId,
  });
}

class QueueRecoveredEvent extends BlocEvent {
  final int messageCount;
  final List<String> failedMessageIds;
  
  QueueRecoveredEvent({
    required this.messageCount,
    this.failedMessageIds = const [],
    super.traceId,
  });
}

// ─── GAME EVENTS ───────────────────────────────────────────────────────────

class GameUpdatedEvent extends BlocEvent {
  final String roomId;
  final String gameType;
  final Map<String, dynamic> gameData;
  final String? currentTurn;
  
  GameUpdatedEvent({
    required this.roomId,
    required this.gameType,
    required this.gameData,
    this.currentTurn,
    super.traceId,
  });
}

class GameMoveMadeEvent extends BlocEvent {
  final String roomId;
  final String playerId;
  final Map<String, dynamic> move;
  final bool isLocal;
  
  GameMoveMadeEvent({
    required this.roomId,
    required this.playerId,
    required this.move,
    this.isLocal = false,
    super.traceId,
  });
}

class GameCompletedEvent extends BlocEvent {
  final String roomId;
  final String winnerId;
  final String gameType;
  final Map<String, dynamic> finalState;
  
  GameCompletedEvent({
    required this.roomId,
    required this.winnerId,
    required this.gameType,
    required this.finalState,
    super.traceId,
  });
}

// ─── USER EVENTS ─────────────────────────────────────────────────────────

class UserOnlineEvent extends BlocEvent {
  final String userId;
  final bool isOnline;
  final DateTime? lastSeen;
  
  UserOnlineEvent({
    required this.userId,
    required this.isOnline,
    this.lastSeen,
    super.traceId,
  });
}

class UserTypingEvent extends BlocEvent {
  final String userId;
  final String roomId;
  final bool isTyping;
  
  UserTypingEvent({
    required this.userId,
    required this.roomId,
    required this.isTyping,
    super.traceId,
  });
}

// ─── SELECTION EVENTS ────────────────────────────────────────────────────

class SelectionChangedEvent extends BlocEvent {
  final String context; // 'chat', 'chat_list', etc.
  final Set<String> selectedIds;
  final bool isSelecting;
  
  SelectionChangedEvent({
    required this.context,
    required this.selectedIds,
    required this.isSelecting,
    super.traceId,
  });
}

// ─── ERROR EVENTS ────────────────────────────────────────────────────────

class ErrorOccurredEvent extends BlocEvent {
  final String source;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
  final bool isFatal;
  
  ErrorOccurredEvent({
    required this.source,
    required this.message,
    this.error,
    this.stackTrace,
    this.isFatal = false,
    super.traceId,
  });
}

class SnackbarRequestedEvent extends BlocEvent {
  final String message;
  final bool isError;
  final Duration duration;
  
  SnackbarRequestedEvent({
    required this.message,
    this.isError = false,
    this.duration = const Duration(seconds: 3),
    super.traceId,
  });
}
