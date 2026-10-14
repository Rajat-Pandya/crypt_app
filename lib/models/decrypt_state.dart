import 'package:flutter/foundation.dart';

/// Decryption state model for tracking message decryption status.
///
/// This model is designed to prevent placeholder caching issues by:
/// - Clearly separating pending/failed states from actual decrypted content
/// - Providing computed properties for UI state management
/// - Supporting copyWith for immutable state updates
/// - Never caching placeholder values as actual decrypted text
class DecryptState {
  /// Whether decryption is currently in progress
  final bool isDecrypting;
  
  /// Whether decryption has failed
  final bool decryptFailed;
  
  /// The successfully decrypted text (null if not yet decrypted or failed)
  final String? decryptedText;
  
  /// Error message if decryption failed
  final String? errorMessage;
  
  /// Timestamp when decryption was attempted
  final DateTime? attemptedAt;
  
  /// Number of retry attempts
  final int retryCount;
  
  /// Whether this state represents a completed successful decryption
  bool get isDecrypted => decryptedText != null && !isDecrypting && !decryptFailed;
  
  /// Whether the message is in a failed state
  bool get hasFailed => decryptFailed && !isDecrypting;
  
  /// Whether decryption is pending (in progress but not failed)
  bool get isPending => isDecrypting && !decryptFailed;
  
  /// Whether we should show a placeholder (decrypting or failed)
  bool get shouldShowPlaceholder => isDecrypting || (decryptFailed && decryptedText == null);
  
  /// Get the display text - either decrypted text or placeholder
  String get displayText {
    if (decryptedText != null) return decryptedText!;
    if (isDecrypting) return '🔒';
    if (decryptFailed) return '⚠️';
    return '🔒';
  }

  const DecryptState({
    this.isDecrypting = false,
    this.decryptFailed = false,
    this.decryptedText,
    this.errorMessage,
    this.attemptedAt,
    this.retryCount = 0,
  });

  /// Initial state - not yet decrypted
  const DecryptState.initial() : 
    isDecrypting = false,
    decryptFailed = false,
    decryptedText = null,
    errorMessage = null,
    attemptedAt = null,
    retryCount = 0;

  /// Pending state - decryption in progress
  const DecryptState.pending() :
    isDecrypting = true,
    decryptFailed = false,
    decryptedText = null,
    errorMessage = null,
    attemptedAt = null,
    retryCount = 0;

  /// Success state - successfully decrypted
  const DecryptState.success(String text, {DateTime? attemptedAt}) :
    isDecrypting = false,
    decryptFailed = false,
    decryptedText = text,
    errorMessage = null,
    attemptedAt = attemptedAt,
    retryCount = 0;

  /// Failed state - decryption failed
  const DecryptState.failed(String error, {DateTime? attemptedAt, int retryCount = 0}) :
    isDecrypting = false,
    decryptFailed = true,
    decryptedText = null,
    errorMessage = error,
    attemptedAt = attemptedAt,
    retryCount = retryCount;

  /// Creates a copy with updated fields
  DecryptState copyWith({
    bool? isDecrypting,
    bool? decryptFailed,
    String? decryptedText,
    String? errorMessage,
    DateTime? attemptedAt,
    int? retryCount,
    bool clearDecryptedText = false,
    bool clearErrorMessage = false,
  }) {
    return DecryptState(
      isDecrypting: isDecrypting ?? this.isDecrypting,
      decryptFailed: decryptFailed ?? this.decryptFailed,
      decryptedText: clearDecryptedText ? null : (decryptedText ?? this.decryptedText),
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      attemptedAt: attemptedAt ?? this.attemptedAt,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  /// Transition to pending state
  DecryptState toPending() => const DecryptState.pending();

  /// Transition to success state
  DecryptState toSuccess(String text) => DecryptState.success(text, attemptedAt: DateTime.now());

  /// Transition to failed state
  DecryptState toFailed(String error) => DecryptState.failed(
    error,
    attemptedAt: DateTime.now(),
    retryCount: retryCount + 1,
  );

  /// Reset to initial state
  DecryptState reset() => const DecryptState.initial();

  /// Check if we should retry decryption
  bool get canRetry => retryCount < 3 && (decryptFailed || isDecrypting);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DecryptState &&
        other.isDecrypting == isDecrypting &&
        other.decryptFailed == decryptFailed &&
        other.decryptedText == decryptedText &&
        other.errorMessage == errorMessage &&
        other.retryCount == retryCount;
  }

  @override
  int get hashCode => Object.hash(
    isDecrypting,
    decryptFailed,
    decryptedText,
    errorMessage,
    retryCount,
  );

  @override
  String toString() {
    return 'DecryptState(isDecrypting: $isDecrypting, decryptFailed: $decryptFailed, '
        'isDecrypted: $isDecrypted, retryCount: $retryCount)';
  }
}

/// Extension methods for working with decryption state in collections
extension DecryptStateMapExtension on Map<String, DecryptState> {
  /// Get all message IDs that are currently being decrypted
  Iterable<String> get pendingIds => 
      entries.where((e) => e.value.isPending).map((e) => e.key);
  
  /// Get all message IDs that have failed decryption
  Iterable<String> get failedIds => 
      entries.where((e) => e.value.hasFailed).map((e) => e.key);
  
  /// Get all message IDs that are successfully decrypted
  Iterable<String> get decryptedIds => 
      entries.where((e) => e.value.isDecrypted).map((e) => e.key);
  
  /// Check if any decryption is in progress
  bool get hasPendingDecryption => values.any((v) => v.isPending);
  
  /// Get count of failed decryptions
  int get failedCount => values.where((v) => v.hasFailed).length;
  
  /// Update state for a specific message
  void updateState(String messageId, DecryptState Function(DecryptState) updater) {
    final current = this[messageId];
    if (current != null) {
      this[messageId] = updater(current);
    }
  }
}

/// ValueNotifier for tracking decryption state of a single message
class DecryptStateNotifier extends ValueNotifier<DecryptState> {
  final String messageId;
  
  DecryptStateNotifier(this.messageId, {DecryptState? initialState}) 
      : super(initialState ?? const DecryptState.initial());
  
  /// Transition to pending
  void setPending() => value = const DecryptState.pending();
  
  /// Transition to success
  void setSuccess(String text) => value = DecryptState.success(text);
  
  /// Transition to failed
  void setFailed(String error) => value = DecryptState.failed(error);
  
  /// Reset state
  void reset() => value = const DecryptState.initial();
  
  /// Update with copyWith
  void update(DecryptState Function(DecryptState) updater) {
    value = updater(value);
  }
}

/// Manager for tracking decryption states of multiple messages
class DecryptStateManager {
  final Map<String, DecryptStateNotifier> _notifiers = {};
  
  /// Get or create a notifier for a message
  DecryptStateNotifier getNotifier(String messageId) {
    return _notifiers.putIfAbsent(
      messageId,
      () => DecryptStateNotifier(messageId),
    );
  }
  
  /// Get current state for a message
  DecryptState getState(String messageId) {
    return _notifiers[messageId]?.value ?? const DecryptState.initial();
  }
  
  /// Set state for a message
  void setState(String messageId, DecryptState state) {
    getNotifier(messageId).value = state;
  }
  
  /// Check if message is decrypted
  bool isDecrypted(String messageId) => getState(messageId).isDecrypted;
  
  /// Check if message decryption is pending
  bool isPending(String messageId) => getState(messageId).isPending;
  
  /// Check if message decryption failed
  bool hasFailed(String messageId) => getState(messageId).hasFailed;
  
  /// Get display text for a message
  String getDisplayText(String messageId) => getState(messageId).displayText;
  
  /// Clear all states
  void clear() {
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
  }
  
  /// Dispose all notifiers
  void dispose() => clear();
  
  /// Get all decrypted message IDs
  Iterable<String> get decryptedMessageIds => 
      _notifiers.entries
          .where((e) => e.value.value.isDecrypted)
          .map((e) => e.key);
  
  /// Get all pending message IDs
  Iterable<String> get pendingMessageIds => 
      _notifiers.entries
          .where((e) => e.value.value.isPending)
          .map((e) => e.key);
  
  /// Get all failed message IDs
  Iterable<String> get failedMessageIds => 
      _notifiers.entries
          .where((e) => e.value.value.hasFailed)
          .map((e) => e.key);
}
