import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// WhatsApp-style message selection controller.
///
/// Manages multi-select state with haptic feedback and proper lifecycle.
/// Uses ValueNotifier for efficient rebuilds without setState.
/// Prevents rebuild storms through granular notifications.
class MessageSelectionController extends ChangeNotifier {
  final Set<String> _selectedIds = {};
  bool _isSelecting = false;
  
  // Debug logging
  static void _dbg(String message) {
    assert(() {
      debugPrint('[MessageSelectionController] $message');
      return true;
    }());
  }

  // ValueNotifiers for granular updates - listeners can subscribe to specific changes
  final ValueNotifier<Set<String>> selectedIdsNotifier = ValueNotifier({});
  final ValueNotifier<bool> isSelectingNotifier = ValueNotifier(false);
  final ValueNotifier<int> selectionCountNotifier = ValueNotifier(0);
  
  // Action availability notifiers
  final ValueNotifier<bool> canReplyNotifier = ValueNotifier(false);
  final ValueNotifier<bool> canCopyNotifier = ValueNotifier(false);
  final ValueNotifier<bool> canDeleteForEveryoneNotifier = ValueNotifier(false);
  final ValueNotifier<bool> canForwardNotifier = ValueNotifier(false);
  
  // Callback to check if messages can be deleted (provided by caller)
  bool Function(String messageId)? canDeleteForEveryoneCheck;

  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);
  bool get isSelecting => _isSelecting;
  int get selectionCount => _selectedIds.length;
  bool get isEmpty => _selectedIds.isEmpty;
  bool get isNotEmpty => _selectedIds.isNotEmpty;

  /// Enter selection mode and select the first message.
  /// Call this on LONG PRESS.
  void enterSelectionMode(String messageId) {
    _dbg('enterSelectionMode: $messageId');
    if (_isSelecting) {
      // Already in selection mode, just toggle this message
      toggleSelection(messageId);
      return;
    }
    
    _isSelecting = true;
    HapticFeedback.mediumImpact();
    _selectedIds.add(messageId);
    _dbg('Selection mode entered, count=${_selectedIds.length}');
    _updateNotifiers();
    _updateActionAvailability();
    notifyListeners();
  }

  /// Toggle selection of a message.
  /// Call this on TAP when already in selection mode.
  void toggleSelection(String messageId) {
    if (!_isSelecting) return;

    if (_selectedIds.contains(messageId)) {
      _selectedIds.remove(messageId);
      if (_selectedIds.isEmpty) {
        exitSelectionMode();
        return;
      }
    } else {
      _selectedIds.add(messageId);
      HapticFeedback.lightImpact();
    }
    _updateNotifiers();
    _updateActionAvailability();
    notifyListeners();
  }

  /// Select all messages.
  void selectAll(Iterable<String> messageIds) {
    if (!_isSelecting) {
      _isSelecting = true;
    }
    _selectedIds.addAll(messageIds);
    _updateNotifiers();
    _updateActionAvailability();
    notifyListeners();
  }

  /// Deselect all messages (keep selection mode active).
  void deselectAll() {
    _selectedIds.clear();
    _updateNotifiers();
    _updateActionAvailability();
    notifyListeners();
  }

  /// Check if a message is selected.
  bool isSelected(String messageId) => _selectedIds.contains(messageId);

  /// Exit selection mode and clear all selections.
  void exitSelectionMode() {
    _dbg('exitSelectionMode');
    if (!_isSelecting && _selectedIds.isEmpty) return;
    
    _isSelecting = false;
    _selectedIds.clear();
    _updateNotifiers();
    _updateActionAvailability();
    notifyListeners();
  }

  /// Handle back button press.
  /// Returns true if handled (was in selection mode), false otherwise.
  bool handleBackPress() {
    if (_isSelecting) {
      exitSelectionMode();
      return true;
    }
    return false;
  }

  /// Clear selection without notifying (for cleanup).
  void clearSilently() {
    _isSelecting = false;
    _selectedIds.clear();
    _updateNotifiers();
    _updateActionAvailability();
  }

  void _updateNotifiers() {
    selectedIdsNotifier.value = Set.from(_selectedIds);
    isSelectingNotifier.value = _isSelecting;
    selectionCountNotifier.value = _selectedIds.length;
  }

  /// Update action availability based on selection.
  void _updateActionAvailability() {
    final count = _selectedIds.length;
    
    // Reply: only when single selection
    canReplyNotifier.value = count == 1;
    
    // Copy: only when single selection and has text
    canCopyNotifier.value = count == 1;
    
    // Delete for everyone: only if all selected messages can be deleted by current user
    // Requires canDeleteForEveryoneCheck callback to be set
    if (canDeleteForEveryoneCheck != null && count > 0) {
      canDeleteForEveryoneNotifier.value = _selectedIds.every(canDeleteForEveryoneCheck!);
    } else {
      canDeleteForEveryoneNotifier.value = false;
    }
    
    // Forward: any selection
    canForwardNotifier.value = count > 0;
  }

  /// Get single selected message ID (for reply/info actions).
  String? get singleSelection =>
      _selectedIds.length == 1 ? _selectedIds.first : null;

  /// Check if only one message is selected.
  bool get hasSingleSelection => _selectedIds.length == 1;

  /// Check if multiple messages are selected.
  bool get hasMultipleSelection => _selectedIds.length > 1;

  @override
  void dispose() {
    selectedIdsNotifier.dispose();
    isSelectingNotifier.dispose();
    selectionCountNotifier.dispose();
    canReplyNotifier.dispose();
    canCopyNotifier.dispose();
    canDeleteForEveryoneNotifier.dispose();
    canForwardNotifier.dispose();
    super.dispose();
  }
}

/// Event for selection changes (for BLoC compatibility).
class SelectionChangedEvent {
  final Set<String> selectedIds;
  final bool isSelecting;
  final String? triggerMessageId;

  const SelectionChangedEvent({
    required this.selectedIds,
    required this.isSelecting,
    this.triggerMessageId,
  });
}

/// Widget that provides selection controller to descendants.
class SelectionControllerProvider extends InheritedNotifier<MessageSelectionController> {
  const SelectionControllerProvider({
    super.key,
    required MessageSelectionController controller,
    required super.child,
  }) : super(notifier: controller);

  static MessageSelectionController of(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<SelectionControllerProvider>();
    assert(provider != null, 'No SelectionControllerProvider found in context');
    return provider!.notifier!;
  }

  static MessageSelectionController? maybeOf(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<SelectionControllerProvider>();
    return provider?.notifier;
  }
}
