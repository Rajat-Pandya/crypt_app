import 'dart:async';
import 'package:flutter/material.dart';

/// Lightweight EventBus optimized for specific event types.
/// 
/// Designed to minimize memory overhead and avoid excessive setState
/// by using typed streams and efficient event routing.
/// 
/// Features:
/// - Pre-typed event streams (no runtime type checks)
/// - Minimal memory footprint
/// - Automatic listener cleanup
/// - No reflection or heavy type operations
/// 
/// Usage:
/// ```dart
/// // Listen to specific events
/// LightweightEventBus().messageUpdated.listen((event) {
///   // Update specific widget without full rebuild
/// });
/// 
/// // Emit events
/// LightweightEventBus().emitMessageUpdated(
///   messageId: 'msg_123',
///   roomId: 'room_456',
/// );
/// ```
class LightweightEventBus {
  static LightweightEventBus? _instance;
  static LightweightEventBus get instance => _instance ??= LightweightEventBus._();
  LightweightEventBus._();

  // Pre-typed controllers for optimal performance
  final _messageUpdatedController = StreamController<MessageUpdatedEvent>.broadcast();
  final _decryptCompletedController = StreamController<DecryptCompletedEvent>.broadcast();
  final _reactionChangedController = StreamController<ReactionChangedEvent>.broadcast();
  final _selectionChangedController = StreamController<SelectionChangedEvent>.broadcast();

  // Streams
  Stream<MessageUpdatedEvent> get messageUpdated => _messageUpdatedController.stream;
  Stream<DecryptCompletedEvent> get decryptCompleted => _decryptCompletedController.stream;
  Stream<ReactionChangedEvent> get reactionChanged => _reactionChangedController.stream;
  Stream<SelectionChangedEvent> get selectionChanged => _selectionChangedController.stream;

  // ─── EMIT METHODS ─────────────────────────────────────────────────────────

  /// Emit message updated event
  void emitMessageUpdated({
    required String messageId,
    required String roomId,
    String? newText,
    bool? isEdited,
    bool? isDeleted,
    DateTime? timestamp,
  }) {
    if (_messageUpdatedController.hasListener) {
      _messageUpdatedController.add(MessageUpdatedEvent(
        messageId: messageId,
        roomId: roomId,
        newText: newText,
        isEdited: isEdited,
        isDeleted: isDeleted,
        timestamp: timestamp ?? DateTime.now(),
      ));
    }
  }

  /// Emit decrypt completed event
  void emitDecryptCompleted({
    required String messageId,
    required bool success,
    String? decryptedText,
    String? error,
    int? retryCount,
  }) {
    if (_decryptCompletedController.hasListener) {
      _decryptCompletedController.add(DecryptCompletedEvent(
        messageId: messageId,
        success: success,
        decryptedText: decryptedText,
        error: error,
        retryCount: retryCount ?? 0,
        timestamp: DateTime.now(),
      ));
    }
  }

  /// Emit reaction changed event
  void emitReactionChanged({
    required String messageId,
    required String emoji,
    required String userId,
    required bool added,
    int? totalCount,
  }) {
    if (_reactionChangedController.hasListener) {
      _reactionChangedController.add(ReactionChangedEvent(
        messageId: messageId,
        emoji: emoji,
        userId: userId,
        added: added,
        totalCount: totalCount ?? 0,
        timestamp: DateTime.now(),
      ));
    }
  }

  /// Emit selection changed event
  void emitSelectionChanged({
    required String context,
    required Set<String> selectedIds,
    required bool isSelecting,
    int? previousCount,
  }) {
    if (_selectionChangedController.hasListener) {
      _selectionChangedController.add(SelectionChangedEvent(
        context: context,
        selectedIds: selectedIds,
        isSelecting: isSelecting,
        previousCount: previousCount ?? 0,
        currentCount: selectedIds.length,
        timestamp: DateTime.now(),
      ));
    }
  }

  // ─── UTILITY METHODS ─────────────────────────────────────────────────────

  /// Check if any listeners exist for a specific event type
  bool hasListeners(EventType type) {
    switch (type) {
      case EventType.messageUpdated:
        return _messageUpdatedController.hasListener;
      case EventType.decryptCompleted:
        return _decryptCompletedController.hasListener;
      case EventType.reactionChanged:
        return _reactionChangedController.hasListener;
      case EventType.selectionChanged:
        return _selectionChangedController.hasListener;
    }
  }

  /// Dispose all controllers
  void dispose() {
    _messageUpdatedController.close();
    _decryptCompletedController.close();
    _reactionChangedController.close();
    _selectionChangedController.close();
    _instance = null;
  }
}

/// Event types for checking listener status
enum EventType {
  messageUpdated,
  decryptCompleted,
  reactionChanged,
  selectionChanged,
}

// ─── EVENT CLASSES ─────────────────────────────────────────────────────────

/// Message updated event - emitted when message content changes
class MessageUpdatedEvent {
  final String messageId;
  final String roomId;
  final String? newText;
  final bool? isEdited;
  final bool? isDeleted;
  final DateTime timestamp;

  const MessageUpdatedEvent({
    required this.messageId,
    required this.roomId,
    this.newText,
    this.isEdited,
    this.isDeleted,
    required this.timestamp,
  });

  @override
  String toString() => 
      'MessageUpdatedEvent(messageId: $messageId, roomId: $roomId, edited: $isEdited)';
}

/// Decrypt completed event - emitted when message decryption finishes
class DecryptCompletedEvent {
  final String messageId;
  final bool success;
  final String? decryptedText;
  final String? error;
  final int retryCount;
  final DateTime timestamp;

  const DecryptCompletedEvent({
    required this.messageId,
    required this.success,
    this.decryptedText,
    this.error,
    this.retryCount = 0,
    required this.timestamp,
  });

  /// Whether this represents a successful decryption
  bool get isSuccess => success && decryptedText != null;

  /// Display text (decrypted or placeholder)
  String get displayText => decryptedText ?? (success ? '🔒' : '⚠️');

  @override
  String toString() => 
      'DecryptCompletedEvent(messageId: $messageId, success: $success, retry: $retryCount)';
}

/// Reaction changed event - emitted when reactions are added/removed
class ReactionChangedEvent {
  final String messageId;
  final String emoji;
  final String userId;
  final bool added; // true = added, false = removed
  final int totalCount;
  final DateTime timestamp;

  const ReactionChangedEvent({
    required this.messageId,
    required this.emoji,
    required this.userId,
    required this.added,
    required this.totalCount,
    required this.timestamp,
  });

  @override
  String toString() => 
      'ReactionChangedEvent(messageId: $messageId, emoji: $emoji, added: $added, total: $totalCount)';
}

/// Selection changed event - emitted when message selection changes
class SelectionChangedEvent {
  final String context; // e.g., 'chat', 'chat_list'
  final Set<String> selectedIds;
  final bool isSelecting;
  final int previousCount;
  final int currentCount;
  final DateTime timestamp;

  const SelectionChangedEvent({
    required this.context,
    required this.selectedIds,
    required this.isSelecting,
    required this.previousCount,
    required this.currentCount,
    required this.timestamp,
  });

  /// Whether selection count increased
  bool get isAdding => currentCount > previousCount;

  /// Whether selection count decreased
  bool get isRemoving => currentCount < previousCount;

  /// Net change in selection count
  int get countDelta => currentCount - previousCount;

  /// Whether this is the first selection
  bool get isFirstSelection => previousCount == 0 && currentCount > 0;

  /// Whether all items were deselected
  bool get isClearing => currentCount == 0 && previousCount > 0;

  @override
  String toString() => 
      'SelectionChangedEvent(context: $context, count: $currentCount, selecting: $isSelecting)';
}

// ─── HELPER MIXIN ───────────────────────────────────────────────────────────

/// Mixin to add EventBus subscription management to widgets
/// 
/// Usage:
/// ```dart
/// class _MyWidgetState extends State<MyWidget> with EventBusListenerMixin {
///   @override
///   void initState() {
///     super.initState();
///     // Listen to specific events without setState overhead
///     onMessageUpdated = (event) {
///       // Update specific UI element
///     };
///   }
/// }
/// ```
mixin EventBusListenerMixin<T extends StatefulWidget> on State<T> {
  final List<StreamSubscription> _subscriptions = [];

  /// Subscribe to message updated events
  set onMessageUpdated(void Function(MessageUpdatedEvent)? handler) {
    _subscriptions.add(
      LightweightEventBus.instance.messageUpdated.listen((event) {
        if (mounted) handler?.call(event);
      }),
    );
  }

  /// Subscribe to decrypt completed events
  set onDecryptCompleted(void Function(DecryptCompletedEvent)? handler) {
    _subscriptions.add(
      LightweightEventBus.instance.decryptCompleted.listen((event) {
        if (mounted) handler?.call(event);
      }),
    );
  }

  /// Subscribe to reaction changed events
  set onReactionChanged(void Function(ReactionChangedEvent)? handler) {
    _subscriptions.add(
      LightweightEventBus.instance.reactionChanged.listen((event) {
        if (mounted) handler?.call(event);
      }),
    );
  }

  /// Subscribe to selection changed events
  set onSelectionChanged(void Function(SelectionChangedEvent)? handler) {
    _subscriptions.add(
      LightweightEventBus.instance.selectionChanged.listen((event) {
        if (mounted) handler?.call(event);
      }),
    );
  }

  /// Add custom subscription
  void addSubscription(StreamSubscription subscription) {
    _subscriptions.add(subscription);
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    super.dispose();
  }
}

// ─── VALUE NOTIFIER VARIANTS ─────────────────────────────────────────────────

/// ValueNotifier wrapper for message update events
class MessageUpdateNotifier extends ValueNotifier<MessageUpdatedEvent?> {
  StreamSubscription? _subscription;

  MessageUpdateNotifier() : super(null) {
    _subscription = LightweightEventBus.instance.messageUpdated.listen((event) {
      value = event;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// ValueNotifier wrapper for decrypt completion events
class DecryptCompleteNotifier extends ValueNotifier<DecryptCompletedEvent?> {
  StreamSubscription? _subscription;

  DecryptCompleteNotifier() : super(null) {
    _subscription = LightweightEventBus.instance.decryptCompleted.listen((event) {
      value = event;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// ValueNotifier wrapper for reaction change events
class ReactionChangeNotifier extends ValueNotifier<ReactionChangedEvent?> {
  StreamSubscription? _subscription;

  ReactionChangeNotifier() : super(null) {
    _subscription = LightweightEventBus.instance.reactionChanged.listen((event) {
      value = event;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// ValueNotifier wrapper for selection change events
class SelectionChangeNotifier extends ValueNotifier<SelectionChangedEvent?> {
  StreamSubscription? _subscription;

  SelectionChangeNotifier() : super(null) {
    _subscription = LightweightEventBus.instance.selectionChanged.listen((event) {
      value = event;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

// ─── EXTENSION METHODS ─────────────────────────────────────────────────────

/// Extension on BuildContext for easy EventBus access
extension EventBusContextExtension on BuildContext {
  /// Get the lightweight event bus instance
  LightweightEventBus get eventBus => LightweightEventBus.instance;
}

/// Extension for common event emission patterns
extension EventBusEmissionExtension on LightweightEventBus {
  /// Emit bulk message updates
  void emitBulkMessageUpdate(List<String> messageIds, String roomId) {
    for (final id in messageIds) {
      emitMessageUpdated(messageId: id, roomId: roomId);
    }
  }

  /// Emit bulk decrypt completions
  void emitBulkDecryptComplete(
    List<String> messageIds,
    bool success, {
    Map<String, String>? decryptedTexts,
  }) {
    for (final id in messageIds) {
      emitDecryptCompleted(
        messageId: id,
        success: success,
        decryptedText: decryptedTexts?[id],
      );
    }
  }

  /// Emit selection toggle (single item)
  void emitSelectionToggle({
    required String context,
    required String itemId,
    required Set<String> currentSelection,
  }) {
    final newSelection = Set<String>.from(currentSelection);
    final wasSelected = newSelection.contains(itemId);
    
    if (wasSelected) {
      newSelection.remove(itemId);
    } else {
      newSelection.add(itemId);
    }
    
    emitSelectionChanged(
      context: context,
      selectedIds: newSelection,
      isSelecting: newSelection.isNotEmpty,
      previousCount: currentSelection.length,
    );
  }
}
