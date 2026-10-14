import 'package:flutter/material.dart';
import '../blocs/chat_bloc.dart';

/// Service for scrolling to specific messages and highlighting them.
/// 
/// Handles both immediate jumps (when message is visible) and
/// deferred jumps (when message needs to be loaded via pagination).
class MessageScrollService {
  final Map<String, GlobalKey> _messageKeys = {};
  final Map<String, AnimationController> _highlightControllers = {};
  
  ChatBloc? _chatBloc;
  BuildContext? _context;

  /// Register a message key for scroll targeting
  void registerMessageKey(String messageId, GlobalKey key) {
    if (messageId.isNotEmpty) {
      _messageKeys[messageId] = key;
    }
  }

  /// Unregister a message key when widget disposes
  void unregisterMessageKey(String messageId) {
    _messageKeys.remove(messageId);
    _highlightControllers.remove(messageId);
  }

  /// Set the ChatBloc for triggering load-more events
  void setChatBloc(ChatBloc bloc) {
    _chatBloc = bloc;
  }

  /// Set the context for showing SnackBars
  void setContext(BuildContext context) {
    _context = context;
  }

  /// Check if a message key is registered
  bool hasMessageKey(String messageId) {
    return _messageKeys.containsKey(messageId);
  }

  /// Jump to a message and optionally highlight it
  /// 
  /// If the message is not in the current view, triggers pagination
  /// until the message is found.
  Future<void> jumpTo(
    String messageId, {
    bool highlight = true,
    Duration scrollDuration = const Duration(milliseconds: 400),
  }) async {
    if (messageId.isEmpty) return;

    // Check if message is already visible
    final key = _messageKeys[messageId];
    
    if (key != null && key.currentContext != null) {
      // Message is visible - scroll to it
      await _scrollToKey(key, scrollDuration);
      
      if (highlight) {
        await _highlightMessage(messageId);
      }
      return;
    }

    // Message not visible - need to load more
    await _loadMoreUntilFound(messageId, highlight: highlight);
  }

  /// Scroll to a specific GlobalKey
  Future<void> _scrollToKey(
    GlobalKey key,
    Duration duration, {
    double alignment = 0.5,
  }) async {
    final context = key.currentContext;
    if (context == null) return;

    await Scrollable.ensureVisible(
      context,
      duration: duration,
      curve: Curves.easeInOut,
      alignment: alignment,
    );
  }

  /// Highlight a message with flash animation
  Future<void> _highlightMessage(String messageId) async {
    // Trigger highlight via ChatBloc event
    _chatBloc?.add(MessageHighlighted(messageId));
    
    // Wait for highlight duration
    await Future.delayed(const Duration(milliseconds: 800));
    
    // Clear highlight
    _chatBloc?.add(MessageHighlightCleared(messageId));
  }

  /// Load more messages until target is found
  Future<void> _loadMoreUntilFound(
    String messageId, {
    bool highlight = true,
  }) async {
    // Emit event to ChatBloc to load more messages
    _chatBloc?.add(LoadMoreUntilMessageFound(messageId));
    
    // Wait and retry up to 10 times (with exponential backoff)
    for (int attempt = 0; attempt < 10; attempt++) {
      await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      
      final key = _messageKeys[messageId];
      if (key != null && key.currentContext != null) {
        // Message found - scroll to it
        await _scrollToKey(key, const Duration(milliseconds: 400));
        
        if (highlight) {
          await _highlightMessage(messageId);
        }
        return;
      }
    }

    // Message not found after retries
    _showNotAvailableSnackBar();
  }

  /// Show snackbar when message is not available
  void _showNotAvailableSnackBar() {
    if (_context == null) return;
    
    ScaffoldMessenger.of(_context!).showSnackBar(
      const SnackBar(
        content: Text('Message not available'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Get the GlobalKey for a message (creates if needed)
  GlobalKey getMessageKey(String messageId) {
    if (!_messageKeys.containsKey(messageId)) {
      _messageKeys[messageId] = GlobalKey(debugLabel: 'message_$messageId');
    }
    return _messageKeys[messageId]!;
  }

  /// Clear all registered keys
  void clear() {
    _messageKeys.clear();
    _highlightControllers.clear();
  }

  /// Dispose service
  void dispose() {
    clear();
    _chatBloc = null;
    _context = null;
  }
}

/// Extension events for ChatBloc
class MessageHighlighted extends ChatEvent {
  final String messageId;
  const MessageHighlighted(this.messageId);
}

class MessageHighlightCleared extends ChatEvent {
  final String messageId;
  const MessageHighlightCleared(this.messageId);
}

class LoadMoreUntilMessageFound extends ChatEvent {
  final String targetMessageId;
  const LoadMoreUntilMessageFound(this.targetMessageId);
}
