import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';


import '../services/chat_util_service.dart';
import '../services/secure_chat_service.dart';
import '../cache/models/message_cache.dart';
import '../repositories/message_repository.dart';
import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';
import '../services/encryption_lifecycle.dart';
import '../services/search_index_service.dart';

// ─── EVENTS ────────────────────────────────────────────────────────────────

abstract class ChatEvent {
  const ChatEvent();
}

class ChatInitialized extends ChatEvent {
  final String roomId;
  final String receiverId;
  const ChatInitialized(this.roomId, this.receiverId);
}

class MessagesLoaded extends ChatEvent {
  final List<MessageCache> messages;
  const MessagesLoaded(this.messages);
}

class SendMessageRequested extends ChatEvent {
  final String text;
  final String? replyToMessageId;
  const SendMessageRequested(this.text, {this.replyToMessageId});
}

class EditMessageRequested extends ChatEvent {
  final String messageId;
  final String newText;
  const EditMessageRequested(this.messageId, this.newText);
}

class DeleteMessageRequested extends ChatEvent {
  final String messageId;
  final bool forEveryone;
  const DeleteMessageRequested(this.messageId, {this.forEveryone = false});
}

class ToggleMessageStar extends ChatEvent {
  final String messageId;
  const ToggleMessageStar(this.messageId);
}

class SelectionModeToggled extends ChatEvent {
  final bool isSelecting;
  const SelectionModeToggled(this.isSelecting);
}

class MessageSelected extends ChatEvent {
  final String messageId;
  const MessageSelected(this.messageId);
}

class MessageDeselected extends ChatEvent {
  final String messageId;
  const MessageDeselected(this.messageId);
}

class ClearSelection extends ChatEvent {
  const ClearSelection();
}

class SearchQueryChanged extends ChatEvent {
  final String query;
  const SearchQueryChanged(this.query);
}

class SearchModeToggled extends ChatEvent {
  const SearchModeToggled();
}

class ReplyToMessageSet extends ChatEvent {
  final String? messageId;
  final String? preview;
  const ReplyToMessageSet({this.messageId, this.preview});
}

class EditMessageModeSet extends ChatEvent {
  final String? messageId;
  final String? currentText;
  const EditMessageModeSet({this.messageId, this.currentText});
}

class TypingStarted extends ChatEvent {
  const TypingStarted();
}

class TypingStopped extends ChatEvent {
  const TypingStopped();
}

class MuteToggled extends ChatEvent {
  final bool isMuted;
  const MuteToggled(this.isMuted);
}

class ErrorOccurred extends ChatEvent {
  final String message;
  const ErrorOccurred(this.message);
}

class RoomExistsChanged extends ChatEvent {
  final bool exists;
  const RoomExistsChanged(this.exists);
}

class EmojiPickerToggled extends ChatEvent {
  final bool show;
  const EmojiPickerToggled(this.show);
}

class LoadingMoreChanged extends ChatEvent {
  final bool isLoading;
  const LoadingMoreChanged(this.isLoading);
}

// Search navigation events
class SearchResultNavigated extends ChatEvent {
  final SearchDirection direction;
  const SearchResultNavigated(this.direction);
}

enum SearchDirection { next, previous }

class SearchFiltersApplied extends ChatEvent {
  final SearchFilters filters;
  const SearchFiltersApplied(this.filters);
}

// Message highlight events
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

// ─── STATE ─────────────────────────────────────────────────────────────────

class ChatState {
  final bool isInitialized;
  final bool isLoading;
  final bool isLoadingMore;
  final List<MessageCache> messages;
  final Map<String, String> decryptedTexts;
  final Set<String> selectedIds;
  final bool isSelecting;
  final String searchQuery;
  final bool isSearchActive;
  final List<String> searchResultIds; // FEATURE 2: Search results
  final int searchResultIndex; // FEATURE 2: Current search result position
  final SearchFilters? activeFilters; // FEATURE 4: Active search filters
  final String? replyToMessageId;
  final String? replyPreview;
  final String? editingMessageId;
  final String? editingText;
  final bool isTyping;
  final bool isMuted;
  final bool keysReady;
  final bool roomExists;
  final bool showEmojiPicker;
  final String? error;
  final String? highlightedMessageId; // FEATURE 3: Highlighted message

  const ChatState({
    this.isInitialized = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.messages = const [],
    this.decryptedTexts = const {},
    this.selectedIds = const {},
    this.isSelecting = false,
    this.searchQuery = '',
    this.isSearchActive = false,
    this.searchResultIds = const [], // FEATURE 2
    this.searchResultIndex = -1, // FEATURE 2
    this.activeFilters, // FEATURE 4
    this.replyToMessageId,
    this.replyPreview,
    this.editingMessageId,
    this.editingText,
    this.isTyping = false,
    this.isMuted = false,
    this.keysReady = false,
    this.roomExists = false,
    this.showEmojiPicker = false,
    this.error,
    this.highlightedMessageId, // FEATURE 3
  });

  ChatState copyWith({
    bool? isInitialized,
    bool? isLoading,
    bool? isLoadingMore,
    List<MessageCache>? messages,
    Map<String, String>? decryptedTexts,
    Set<String>? selectedIds,
    bool? isSelecting,
    String? searchQuery,
    bool? isSearchActive,
    List<String>? searchResultIds,
    int? searchResultIndex,
    SearchFilters? activeFilters,
    String? replyToMessageId,
    String? replyPreview,
    String? editingMessageId,
    String? editingText,
    bool? isTyping,
    bool? isMuted,
    bool? keysReady,
    bool? roomExists,
    bool? showEmojiPicker,
    String? error,
    String? highlightedMessageId,
  }) {
    return ChatState(
      isInitialized: isInitialized ?? this.isInitialized,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      messages: messages ?? this.messages,
      decryptedTexts: decryptedTexts ?? this.decryptedTexts,
      selectedIds: selectedIds ?? this.selectedIds,
      isSelecting: isSelecting ?? this.isSelecting,
      searchQuery: searchQuery ?? this.searchQuery,
      isSearchActive: isSearchActive ?? this.isSearchActive,
      searchResultIds: searchResultIds ?? this.searchResultIds,
      searchResultIndex: searchResultIndex ?? this.searchResultIndex,
      activeFilters: activeFilters ?? this.activeFilters,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyPreview: replyPreview ?? this.replyPreview,
      editingMessageId: editingMessageId ?? this.editingMessageId,
      editingText: editingText ?? this.editingText,
      isTyping: isTyping ?? this.isTyping,
      isMuted: isMuted ?? this.isMuted,
      keysReady: keysReady ?? this.keysReady,
      roomExists: roomExists ?? this.roomExists,
      showEmojiPicker: showEmojiPicker ?? this.showEmojiPicker,
      error: error ?? this.error,
      highlightedMessageId: highlightedMessageId ?? this.highlightedMessageId,
    );
  }

  bool get hasReply => replyToMessageId != null;
  bool get isEditing => editingMessageId != null;
  int get selectedCount => selectedIds.length;
  
  List<MessageCache> get filteredMessages {
    if (!isSearchActive || searchQuery.isEmpty) return messages;
    final query = searchQuery.toLowerCase();
    return messages.where((m) {
      final text = decryptedTexts[m.messageId]?.toLowerCase() ?? '';
      return text.contains(query);
    }).toList();
  }
  
  // FEATURE 2: Get current search result message
  MessageCache? get currentSearchResult {
    if (searchResultIds.isEmpty || searchResultIndex < 0 || searchResultIndex >= searchResultIds.length) {
      return null;
    }
    final messageId = searchResultIds[searchResultIndex];
    return messages.firstWhere(
      (m) => m.messageId == messageId,
      orElse: () => messages.first,
    );
  }
  
  // FEATURE 2: Check if message is in search results
  bool isInSearchResults(String messageId) {
    return searchResultIds.contains(messageId);
  }
  
  // FEATURE 2: Get search results count
  int get searchResultsCount => searchResultIds.length;
}

// ─── BLOC ──────────────────────────────────────────────────────────────────

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final String roomId;
  final String receiverId;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _messageRepoSubscription;
  Timer? _typingTimer;
  final SearchIndexService _searchIndexService = SearchIndexService.instance;

  ChatBloc({required this.roomId, required this.receiverId})
      : super(const ChatState()) {
    on<ChatInitialized>(_onInitialized);
    on<MessagesLoaded>(_onMessagesLoaded);
    on<SendMessageRequested>(_onSendMessage);
    on<EditMessageRequested>(_onEditMessage);
    on<DeleteMessageRequested>(_onDeleteMessage);
    on<ToggleMessageStar>(_onToggleStar);
    on<SelectionModeToggled>(_onSelectionModeToggled);
    on<MessageSelected>(_onMessageSelected);
    on<MessageDeselected>(_onMessageDeselected);
    on<ClearSelection>(_onClearSelection);
    on<SearchQueryChanged>(_onSearchQueryChanged);
    on<SearchModeToggled>(_onSearchModeToggled);
    on<ReplyToMessageSet>(_onReplyToMessageSet);
    on<EditMessageModeSet>(_onEditMessageModeSet);
    on<TypingStarted>(_onTypingStarted);
    on<TypingStopped>(_onTypingStopped);
    on<MuteToggled>(_onMuteToggled);
    on<ErrorOccurred>(_onErrorOccurred);
    on<RoomExistsChanged>(_onRoomExistsChanged);
    on<EmojiPickerToggled>(_onEmojiPickerToggled);
    on<LoadingMoreChanged>(_onLoadingMoreChanged);
    // Search events
    on<SearchResultNavigated>(_onSearchResultNavigated);
    on<SearchFiltersApplied>(_onSearchFiltersApplied);
    on<MessageHighlighted>(_onMessageHighlighted);
    on<MessageHighlightCleared>(_onMessageHighlightCleared);
    on<LoadMoreUntilMessageFound>(_onLoadMoreUntilMessageFound);
  }

  void _onInitialized(ChatInitialized event, Emitter<ChatState> emit) {
    emit(state.copyWith(isLoading: true));
    // Load messages from repository
    _subscribeToMessages();
  }

  void _onMessagesLoaded(MessagesLoaded event, Emitter<ChatState> emit) {
    emit(state.copyWith(
      isInitialized: true,
      isLoading: false,
      messages: event.messages,
    ));
  }

  Future<void> _onSendMessage(
    SendMessageRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));
    
    try {
      // Get encryption keys
      final currentUserId = _currentUserId;
      if (currentUserId.isEmpty) {
        throw Exception('User not authenticated');
      }

      // Load receiver's public key
      final receiverKeyResult = await ChatUtilService.loadReceiverPublicKey(receiverId);
      if (receiverKeyResult == null) {
        throw Exception('Receiver public key not found');
      }

      // Load sender's public key
      final myKeyResult = await EncryptionLifecycleService.getMyPublicKey(currentUserId);
      if (myKeyResult == null) {
        throw Exception('Sender public key not found');
      }

      // Call SecureChatService.sendSecureMessage with encryption
      await SecureChatService.sendSecureMessage(
        currentUserId: currentUserId,
        receiverId: receiverId,
        text: event.text,
        receiverPublicKey: receiverKeyResult.publicKey,
        senderPublicKey: myKeyResult.publicKey,
        senderKeyVersion: myKeyResult.version,
        receiverKeyVersion: receiverKeyResult.version,
        replyTo: event.replyToMessageId != null
            ? {'messageId': event.replyToMessageId}
            : null,
      );
      
      // Index sent message for search (optimistic indexing)
      _searchIndexService.indexMessage(
        messageId: '${roomId}_${DateTime.now().millisecondsSinceEpoch}',
        plaintext: event.text,
        senderId: currentUserId,
        timestamp: DateTime.now(),
        roomId: roomId,
      );
      
      // Clear reply state
      emit(state.copyWith(
        isLoading: false,
        replyToMessageId: null,
        replyPreview: null,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Failed to send message: $e',
      ));
    }
  }

  void _onSelectionModeToggled(
    SelectionModeToggled event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(
      isSelecting: event.isSelecting,
      selectedIds: event.isSelecting ? state.selectedIds : const {},
    ));
  }

  void _onMessageSelected(MessageSelected event, Emitter<ChatState> emit) {
    final newSelected = Set<String>.from(state.selectedIds)
      ..add(event.messageId);
    emit(state.copyWith(
      selectedIds: newSelected,
      isSelecting: true,
    ));
    _emitSelectionEvent(emit, newSelected, true);
  }

  void _onMessageDeselected(MessageDeselected event, Emitter<ChatState> emit) {
    final newSelected = Set<String>.from(state.selectedIds)
      ..remove(event.messageId);
    emit(state.copyWith(
      selectedIds: newSelected,
      isSelecting: newSelected.isNotEmpty,
    ));
    _emitSelectionEvent(emit, newSelected, newSelected.isNotEmpty);
  }

  void _onClearSelection(ClearSelection event, Emitter<ChatState> emit) {
    emit(state.copyWith(
      selectedIds: const {},
      isSelecting: false,
    ));
    _emitSelectionEvent(emit, const {}, false);
  }

  void _emitSelectionEvent(Emitter<ChatState> emit, Set<String> selectedIds, bool isSelecting) {
    // Selection event logic removed - was dead code
  }

  void _onSearchQueryChanged(
    SearchQueryChanged event,
    Emitter<ChatState> emit,
  ) async {
    // FEATURE 2: Perform indexed search
    final query = event.query;
    
    if (query.isEmpty) {
      emit(state.copyWith(
        searchQuery: query,
        searchResultIds: const [],
        searchResultIndex: -1,
      ));
      return;
    }
    
    // Perform search using SearchIndexService
    final results = _searchIndexService.search(
      query,
      roomId: roomId,
      filters: state.activeFilters,
    );
    
    emit(state.copyWith(
      searchQuery: query,
      searchResultIds: results,
      searchResultIndex: results.isNotEmpty ? 0 : -1,
    ));
  }
  
  // FEATURE 2: Navigate search results
  void _onSearchResultNavigated(
    SearchResultNavigated event,
    Emitter<ChatState> emit,
  ) {
    if (state.searchResultIds.isEmpty) return;
    
    int newIndex;
    if (event.direction == SearchDirection.next) {
      newIndex = (state.searchResultIndex + 1) % state.searchResultIds.length;
    } else {
      newIndex = (state.searchResultIndex - 1 + state.searchResultIds.length) % 
                  state.searchResultIds.length;
    }
    
    emit(state.copyWith(searchResultIndex: newIndex));
  }
  
  // FEATURE 4: Apply search filters
  void _onSearchFiltersApplied(
    SearchFiltersApplied event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(activeFilters: event.filters));
    
    // Re-run search with new filters if query exists
    if (state.searchQuery.isNotEmpty) {
      final results = _searchIndexService.search(
        state.searchQuery,
        roomId: roomId,
        filters: event.filters,
      );
      
      emit(state.copyWith(
        searchResultIds: results,
        searchResultIndex: results.isNotEmpty ? 0 : -1,
      ));
    }
  }
  
  // FEATURE 3: Message highlighting
  void _onMessageHighlighted(
    MessageHighlighted event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(highlightedMessageId: event.messageId));
  }
  
  void _onMessageHighlightCleared(
    MessageHighlightCleared event,
    Emitter<ChatState> emit,
  ) {
    if (state.highlightedMessageId == event.messageId) {
      emit(state.copyWith(highlightedMessageId: null));
    }
  }
  
  Future<void> _onLoadMoreUntilMessageFound(
    LoadMoreUntilMessageFound event,
    Emitter<ChatState> emit,
  ) async {
    const maxPages = 10;
    const pageSize = 50;
    
    debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: START - target=${event.targetMessageId}');
    
    // Step 1: Emit isLoadingMore: true
    emit(state.copyWith(isLoadingMore: true, error: null));
    
    try {
      // Find the oldest loaded message to use as cursor
      DateTime? oldestTimestamp;
      if (state.messages.isNotEmpty) {
        // Sort by timestamp ascending to find oldest
        final sortedMessages = List<MessageCache>.from(state.messages)
          ..sort((a, b) => (a.timestamp ?? DateTime.now())
              .compareTo(b.timestamp ?? DateTime.now()));
        oldestTimestamp = sortedMessages.first.timestamp;
      }
      
      debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: oldestTimestamp=$oldestTimestamp, messagesCount=${state.messages.length}');
      
      // Step 2-4: Load pages until found or limit reached
      for (int page = 0; page < maxPages; page++) {
        debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: loading page ${page + 1}/$maxPages');
        
        // Build query with cursor pagination
        var query = FirebaseFirestore.instance
            .collection('chat_rooms')
            .doc(roomId)
            .collection('messages')
            .orderBy('timestamp', descending: false)
            .limit(pageSize);
        
        // Add cursor if we have an oldest timestamp
        if (oldestTimestamp != null) {
          query = query.startAfter([Timestamp.fromDate(oldestTimestamp)]);
        }
        
        final snapshot = await query.get();
        
        if (snapshot.docs.isEmpty) {
          debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: no more messages available');
          break;
        }
        
        // Step 3: Check if target message is in this batch
        final newMessages = snapshot.docs.map((doc) {
          final data = doc.data();
          final cache = MessageCache()
            ..messageId = doc.id
            ..senderId = data['senderId'] as String? ?? ''
            ..encryptedText = data['text'] as String? ?? ''
            ..timestamp = (data['timestamp'] as Timestamp?)?.toDate()
            ..encryptedAesKey = data['aesKey'] as String? ?? ''
            ..encryptedAesKeySender = data['aesKeySender'] as String?
            ..iv = data['iv'] as String? ?? ''
            ..senderKeyVersion = data['senderKeyVersion'] as String?
            ..receiverKeyVersion = data['receiverKeyVersion'] as String?
            ..reactions = (data['reactions'] as Map<String, dynamic>?)?.map(
                  (key, value) => MapEntry(key, value is List ? value.cast<String>() : <String>[]),
                ) ?? {}
            ..replyToMessageId = (data['replyTo']?['messageId']) as String?
            ..replyPreview = (data['replyTo']?['preview']) as String?
            ..starred = data['starred'] as bool? ?? false
            ..deletedFor = List<String>.from(data['deletedFor'] ?? [])
            ..status = data['status'] as String? ?? 'sent';
          return cache;
        }).toList();
        
        // Check if target message is in this batch
        final found = newMessages.any((m) => m.messageId == event.targetMessageId);
        
        if (found) {
          debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: TARGET FOUND after ${page + 1} pages');
          
          // Merge new messages with existing messages
          final updatedMessages = [...state.messages, ...newMessages];
          
          // Step 5: Emit highlightedMessageId and isLoadingMore: false
          emit(state.copyWith(
            messages: updatedMessages,
            isLoadingMore: false,
            highlightedMessageId: event.targetMessageId,
            error: null,
          ));
          
          debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: END - success');
          return;
        }
        
        // Update cursor for next page
        if (newMessages.isNotEmpty) {
          final lastMessage = newMessages.last;
          if (lastMessage.timestamp != null) {
            oldestTimestamp = lastMessage.timestamp;
          }
        }
        
        // Emit intermediate state with loaded messages
        final updatedMessages = [...state.messages, ...newMessages];
        emit(state.copyWith(messages: updatedMessages));
        
        debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: page ${page + 1} loaded, total messages=${updatedMessages.length}');
      }
      
      // Step 6: Message not found after limit - emit error
      debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: MESSAGE NOT FOUND after $maxPages pages');
      emit(state.copyWith(
        isLoadingMore: false,
        error: 'Message not found in history',
        highlightedMessageId: null,
      ));
      
    } catch (e) {
      debugPrint('[ChatBloc] _onLoadMoreUntilMessageFound: ERROR - $e');
      emit(state.copyWith(
        isLoadingMore: false,
        error: 'Failed to load messages: $e',
        highlightedMessageId: null,
      ));
    }
  }

  void _onSearchModeToggled(
    SearchModeToggled event,
    Emitter<ChatState> emit,
  ) {
    // Toggle search mode using proper isSearchActive field
    final newIsSearchActive = !state.isSearchActive;
    emit(state.copyWith(
      isSearchActive: newIsSearchActive,
      searchQuery: newIsSearchActive ? state.searchQuery : '',
    ));
  }

  void _onReplyToMessageSet(
    ReplyToMessageSet event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(
      replyToMessageId: event.messageId,
      replyPreview: event.preview,
    ));
  }

  void _onEditMessageModeSet(
    EditMessageModeSet event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(
      editingMessageId: event.messageId,
      editingText: event.currentText,
    ));
  }

  void _onTypingStarted(TypingStarted event, Emitter<ChatState> emit) {
    emit(state.copyWith(isTyping: true));
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      add(const TypingStopped());
    });
  }

  void _onTypingStopped(TypingStopped event, Emitter<ChatState> emit) {
    emit(state.copyWith(isTyping: false));
  }

  void _onMuteToggled(MuteToggled event, Emitter<ChatState> emit) {
    emit(state.copyWith(isMuted: event.isMuted));
  }

  void _onErrorOccurred(ErrorOccurred event, Emitter<ChatState> emit) {
    emit(state.copyWith(error: event.message));
  }

  Future<void> _onEditMessage(
    EditMessageRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));
    try {
      // Get the current message to retrieve existing session keys
      final message = state.messages.firstWhere(
        (m) => m.messageId == event.messageId,
        orElse: () => throw Exception('Message not found'),
      );
      
      // Get current user's private key
      final privateKeyStr = await EncryptionLifecycleService.getPrivateKey();
      if (privateKeyStr == null) {
        throw Exception('Private key not found');
      }
      final privateKey = await EncryptionLifecycleService.getPrivateKeyParsed();
      
      // Decrypt the existing session AES key
      // Try receiver's key first (for messages received), then sender's key (for messages sent)
      String? sessionAesKey;
      String? originalIv;
      final messageData = await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(roomId)
          .collection('messages')
          .doc(event.messageId)
          .get();
      
      if (messageData.exists) {
        final data = messageData.data()!;
        final encryptedAesKeyReceiver = data['aesKey'] as String?;
        final encryptedAesKeySender = data['aesKeySender'] as String?;
        originalIv = data['iv'] as String?;
        
        // Try to decrypt the session key
        try {
          if (encryptedAesKeyReceiver != null && privateKey != null) {
            sessionAesKey = await RSAHelper.decrypt(encryptedAesKeyReceiver, privateKey);
          }
        } catch (_) {
          // Try sender key
          if (encryptedAesKeySender != null && privateKey != null) {
            sessionAesKey = await RSAHelper.decrypt(encryptedAesKeySender, privateKey);
          }
        }
      }
      
      if (sessionAesKey == null || originalIv == null) {
        throw Exception('Failed to retrieve session encryption keys');
      }
      
      // BUG 3 FIX: Encrypt new text with the EXISTING session key and original IV
      // NOT with a fresh random key from encryptMessage()
      final encryptedData = await EncryptionHelper.encryptWithKey(
        event.newText,
        sessionAesKey,
        originalIv,
      );
      
      // Get receiver's public key for re-encrypting
      final receiverKeyResult = await ChatUtilService.loadReceiverPublicKey(receiverId);
      final myKeyResult = await EncryptionLifecycleService.getMyPublicKey(_currentUserId);
      
      if (receiverKeyResult == null || myKeyResult == null) {
        throw Exception('Public keys not found');
      }
      
      // Re-encrypt the session key for both parties
      final newAesKeyForReceiver = await RSAHelper.encrypt(sessionAesKey, receiverKeyResult.publicKey);
      final newAesKeyForSender = await RSAHelper.encrypt(sessionAesKey, myKeyResult.publicKey);
      
      // Call ChatUtilService.editMessage with proper encryption
      await ChatUtilService.editMessage(
        chatRoomId: roomId,
        messageId: event.messageId,
        newEncryptedText: encryptedData['text']!,
        newAesKeyForReceiver: newAesKeyForReceiver,
        newAesKeyForSender: newAesKeyForSender,
        newIv: encryptedData['iv']!,
        originalEncryptedText: message.encryptedText,
      );
      emit(state.copyWith(
        isLoading: false,
        editingMessageId: null,
        editingText: null,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Edit failed: $e',
      ));
    }
  }

  Future<void> _onDeleteMessage(
    DeleteMessageRequested event,
    Emitter<ChatState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));
    try {
      // BUG 2 FIX: Fetch DocumentSnapshot before calling deleteMessages
      final doc = await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(roomId)
          .collection('messages')
          .doc(event.messageId)
          .get();
      
      await ChatUtilService.deleteMessages(
        chatRoomId: roomId,
        messages: [doc],
        currentUserId: _currentUserId,
        forEveryone: event.forEveryone,
      );
      emit(state.copyWith(isLoading: false));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Delete failed: $e',
      ));
    }
  }

  Future<void> _onToggleStar(
    ToggleMessageStar event,
    Emitter<ChatState> emit,
  ) async {
    try {
      // Find the message to toggle
      final messageIndex = state.messages.indexWhere((m) => m.messageId == event.messageId);
      if (messageIndex == -1) return;
      
      final message = state.messages[messageIndex];
      final newStarred = !(message.starred ?? false);
      
      // Optimistically update the message in state
      final updatedMessages = List<MessageCache>.from(state.messages);
      updatedMessages[messageIndex] = message.copyWith(starred: newStarred);
      
      emit(state.copyWith(messages: updatedMessages));
      
      // Call ChatUtilService.toggleMessageStar
      await ChatUtilService.toggleMessageStar(
        chatRoomId: roomId,
        messageId: event.messageId,
        userId: _currentUserId,
      );
    } catch (e) {
      // Roll back on error by reloading messages
      emit(state.copyWith(error: 'Star toggle failed: $e'));
      // Revert the optimistic update
      add(const ChatInitialized('', ''));
    }
  }

  void _subscribeToMessages() {
    // Subscribe to MessageRepository.getMessagesStream
    _messageRepoSubscription?.cancel();
    _messageRepoSubscription = MessageRepository()
        .getMessagesStream(chatRoomId: roomId, limit: 50)
        .listen(
      (messages) {
        // Convert Message to MessageCache
        final cachedMessages = messages.map((m) {
          final cache = MessageCache()
            ..messageId = m.id
            ..senderId = m.senderId
            ..encryptedText = m.text
            ..timestamp = m.timestamp?.toDate()
            ..encryptedAesKey = m.aesKey ?? ''
            ..encryptedAesKeySender = m.aesKeySender
            ..iv = m.iv ?? ''
            ..senderKeyVersion = m.senderKeyVersion
            ..receiverKeyVersion = m.receiverKeyVersion
            ..reactions = (m.reactions)?.map(
                  (key, value) => MapEntry(key, value is List ? value.cast<String>() : <String>[]),
                ) ?? {}
            ..replyToMessageId = (m.replyTo?['messageId']) as String?
            ..replyPreview = (m.replyTo?['preview']) as String?
            ..starred = m.starred
            ..deletedFor = m.deletedFor
            ..status = m.status;
          return cache;
        }).toList();
        add(MessagesLoaded(cachedMessages));
      },
      onError: (error) {
        // Error handling removed - was dead EventBus code
      },
    );
  }

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  void _onRoomExistsChanged(
    RoomExistsChanged event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(roomExists: event.exists));
  }

  void _onEmojiPickerToggled(
    EmojiPickerToggled event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(showEmojiPicker: event.show));
  }

  void _onLoadingMoreChanged(
    LoadingMoreChanged event,
    Emitter<ChatState> emit,
  ) {
    emit(state.copyWith(isLoadingMore: event.isLoading));
  }


  @override
  Future<void> close() {
    _messageSubscription?.cancel();
    _messageRepoSubscription?.cancel();
    _typingTimer?.cancel();
    return super.close();
  }
}
