import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/message_ui_state.dart';

/// Per-message state manager using ValueNotifier for granular rebuilds.
/// 
/// Each message bubble gets its own state, allowing:
/// - Individual rebuilds for edits/decrypts
/// - No full list rebuilds
/// - Smooth scrolling preserved
/// 
/// Usage:
/// ```dart
/// final state = MessageStateManager().getState(messageId);
/// return ValueListenableBuilder<MessageUIState>(
///   valueListenable: state,
///   builder: (context, state, child) => MessageBubble(state: state),
/// );
/// ```
class MessageStateManager {
  static final MessageStateManager _instance = MessageStateManager._internal();
  factory MessageStateManager() => _instance;
  MessageStateManager._internal();
  
  // Map of messageId to state
  final Map<String, ValueNotifier<MessageUIState>> _states = {};
  final Map<String, StreamSubscription> _subscriptions = {};
  final Map<String, Timer> _cleanupTimers = {};
  
  /// Get or create state for a message.
  ValueNotifier<MessageUIState> getState(String messageId, {MessageUIState? initialState}) {
    // Cancel any pending cleanup
    _cleanupTimers[messageId]?.cancel();
    _cleanupTimers.remove(messageId);
    
    if (!_states.containsKey(messageId)) {
      _states[messageId] = ValueNotifier<MessageUIState>(
        initialState ?? MessageUIState.initial(messageId),
      );
    }
    
    return _states[messageId]!;
  }
  
  /// Update state for a message.
  void updateState(String messageId, MessageUIState Function(MessageUIState current) updater) {
    final state = _states[messageId];
    if (state != null) {
      state.value = updater(state.value);
    }
  }
  
  /// Update plaintext (e.g., after decrypt).
  void setPlaintext(String messageId, String plaintext, {bool isDecrypted = true}) {
    updateState(messageId, (s) => s.copyWith(
      plaintext: plaintext,
      isDecrypted: isDecrypted,
      isDecrypting: false,
    ));
  }
  
  /// Update edit state.
  void setEditing(String messageId, bool isEditing) {
    updateState(messageId, (s) => s.copyWith(isEditing: isEditing));
  }
  
  /// Update reactions.
  void setReactions(String messageId, Map<String, dynamic> reactions) {
    updateState(messageId, (s) => s.copyWith(reactions: reactions));
  }
  
  /// Update from edited message.
  void updateFromEdit(String messageId, {
    required String newPlaintext,
    required DateTime editedAt,
  }) {
    updateState(messageId, (s) => s.copyWith(
      plaintext: newPlaintext,
      isEdited: true,
      editedAt: editedAt,
      isEditing: false,
    ));
  }
  
  /// Mark as decrypting.
  void setDecrypting(String messageId) {
    updateState(messageId, (s) => s.copyWith(isDecrypting: true));
  }
  
  /// Mark as decrypt failed.
  void setDecryptFailed(String messageId) {
    updateState(messageId, (s) => s.copyWith(
      isDecrypting: false,
      isDecrypted: false,
      plaintext: '🔒',
    ));
  }
  
  /// Clear state for a message (call after message deleted).
  void clearState(String messageId) {
    _states[messageId]?.dispose();
    _states.remove(messageId);
    _subscriptions[messageId]?.cancel();
    _subscriptions.remove(messageId);
    _cleanupTimers[messageId]?.cancel();
    _cleanupTimers.remove(messageId);
  }
  
  /// Schedule cleanup for a message (call when message leaves viewport).
  void scheduleCleanup(String messageId, {Duration delay = const Duration(minutes: 2)}) {
    _cleanupTimers[messageId]?.cancel();
    _cleanupTimers[messageId] = Timer(delay, () {
      clearState(messageId);
    });
  }
  
  /// Cancel scheduled cleanup.
  void cancelCleanup(String messageId) {
    _cleanupTimers[messageId]?.cancel();
    _cleanupTimers.remove(messageId);
  }
  
  /// Get current state (for non-reactive access).
  MessageUIState? getCurrentState(String messageId) {
    return _states[messageId]?.value;
  }
  
  /// Check if state exists.
  bool hasState(String messageId) => _states.containsKey(messageId);
  
  /// Clear all states (e.g., on logout).
  void clearAllStates() {
    for (final state in _states.values) {
      state.dispose();
    }
    _states.clear();
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
    for (final timer in _cleanupTimers.values) {
      timer.cancel();
    }
    _cleanupTimers.clear();
  }
  
  /// Get active state count (for debugging).
  int get activeStateCount => _states.length;
}
