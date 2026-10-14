import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:connectivity_plus/connectivity_plus.dart';


import '../services/chat_util_service.dart';
import '../services/secure_chat_service.dart';

// ─── EVENTS ────────────────────────────────────────────────────────────────

abstract class ConnectivityEvent {
  const ConnectivityEvent();
}

class ConnectivityInitialized extends ConnectivityEvent {
  const ConnectivityInitialized();
}

class ConnectivityChanged extends ConnectivityEvent {
  final bool isOnline;
  final String? networkType;
  const ConnectivityChanged(this.isOnline, {this.networkType});
}

class ReconnectRequested extends ConnectivityEvent {
  const ReconnectRequested();
}

class ReconnectStarted extends ConnectivityEvent {
  const ReconnectStarted();
}

class ReconnectCompleted extends ConnectivityEvent {
  final int messagesSynced;
  const ReconnectCompleted(this.messagesSynced);
}

class ReconnectFailed extends ConnectivityEvent {
  final String error;
  const ReconnectFailed(this.error);
}

class QueueRecoveryStarted extends ConnectivityEvent {
  const QueueRecoveryStarted();
}

class QueueRecoveryCompleted extends ConnectivityEvent {
  final int messageCount;
  const QueueRecoveryCompleted(this.messageCount);
}

// ─── STATE ─────────────────────────────────────────────────────────────────

class ConnectivityState {
  final bool isInitialized;
  final bool isOnline;
  final bool isReconnecting;
  final String? networkType;
  final int messagesSynced;
  final int queueMessageCount;
  final String? error;

  const ConnectivityState({
    this.isInitialized = false,
    this.isOnline = true,
    this.isReconnecting = false,
    this.networkType,
    this.messagesSynced = 0,
    this.queueMessageCount = 0,
    this.error,
  });

  ConnectivityState copyWith({
    bool? isInitialized,
    bool? isOnline,
    bool? isReconnecting,
    String? networkType,
    int? messagesSynced,
    int? queueMessageCount,
    String? error,
  }) {
    return ConnectivityState(
      isInitialized: isInitialized ?? this.isInitialized,
      isOnline: isOnline ?? this.isOnline,
      isReconnecting: isReconnecting ?? this.isReconnecting,
      networkType: networkType ?? this.networkType,
      messagesSynced: messagesSynced ?? this.messagesSynced,
      queueMessageCount: queueMessageCount ?? this.queueMessageCount,
      error: error ?? this.error,
    );
  }
}

// ─── BLOC ──────────────────────────────────────────────────────────────────

class ConnectivityBloc extends Bloc<ConnectivityEvent, ConnectivityState> {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  ConnectivityBloc() : super(const ConnectivityState()) {
    on<ConnectivityInitialized>(_onInitialized);
    on<ConnectivityChanged>(_onConnectivityChanged);
    on<ReconnectRequested>(_onReconnectRequested);
    on<ReconnectStarted>(_onReconnectStarted);
    on<ReconnectCompleted>(_onReconnectCompleted);
    on<ReconnectFailed>(_onReconnectFailed);
    on<QueueRecoveryStarted>(_onQueueRecoveryStarted);
    on<QueueRecoveryCompleted>(_onQueueRecoveryCompleted);

    _init();
  }

  void _init() {
    add(const ConnectivityInitialized());
  }

  Future<void> _onInitialized(
    ConnectivityInitialized event,
    Emitter<ConnectivityState> emit,
  ) async {
    final connectivityResults = await Connectivity().checkConnectivity();
    _handleConnectivityChange(connectivityResults, emit);

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (results) {
        final isOnline = results.isNotEmpty && 
                         results.any((r) => r != ConnectivityResult.none);
        add(ConnectivityChanged(isOnline));
      },
    );

    emit(state.copyWith(isInitialized: true));
  }

  void _onConnectivityChanged(
    ConnectivityChanged event,
    Emitter<ConnectivityState> emit,
  ) {
    final results = event.isOnline 
        ? [ConnectivityResult.wifi] 
        : [ConnectivityResult.none];
    _handleConnectivityChange(results, emit);

    // If coming back online, trigger reconnect
    if (event.isOnline && !state.isOnline) {
      add(const ReconnectRequested());
    }
  }

  void _handleConnectivityChange(
    List<ConnectivityResult> results,
    Emitter<ConnectivityState> emit,
  ) {
    final isOnline = results.isNotEmpty && 
                     results.any((r) => r != ConnectivityResult.none);
    final networkType = results.isNotEmpty ? _mapNetworkType(results.first) : 'none';
    emit(state.copyWith(
      isOnline: isOnline,
      networkType: networkType,
    ));
  }

  String _mapNetworkType(ConnectivityResult result) {
    switch (result) {
      case ConnectivityResult.wifi:
        return 'wifi';
      case ConnectivityResult.mobile:
        return 'mobile';
      default:
        return 'none';
    }
  }

  Future<void> _onReconnectRequested(
    ReconnectRequested event,
    Emitter<ConnectivityState> emit,
  ) async {
    add(const ReconnectStarted());

    try {
      // Wait a moment for connection to stabilize
      await Future.delayed(const Duration(seconds: 2));

      // Sync messages from offline queue
      // This would integrate with OfflineQueueManager
      final messagesSynced = await _syncOfflineMessages();

      add(ReconnectCompleted(messagesSynced));
    } catch (e) {
      add(ReconnectFailed(e.toString()));
    }
  }

  void _onReconnectStarted(
    ReconnectStarted event,
    Emitter<ConnectivityState> emit,
  ) {
    emit(state.copyWith(isReconnecting: true));
  }

  void _onReconnectCompleted(
    ReconnectCompleted event,
    Emitter<ConnectivityState> emit,
  ) {
    emit(state.copyWith(
      isReconnecting: false,
      messagesSynced: event.messagesSynced,
    ));

    // Also trigger queue recovery
    add(const QueueRecoveryStarted());
  }

  void _onReconnectFailed(
    ReconnectFailed event,
    Emitter<ConnectivityState> emit,
  ) {
    emit(state.copyWith(
      isReconnecting: false,
      error: event.error,
    ));
  }

  void _onQueueRecoveryStarted(
    QueueRecoveryStarted event,
    Emitter<ConnectivityState> emit,
  ) {
    // Recover offline queue
    _recoverQueue();
  }

  void _onQueueRecoveryCompleted(
    QueueRecoveryCompleted event,
    Emitter<ConnectivityState> emit,
  ) {
    emit(state.copyWith(queueMessageCount: event.messageCount));
  }

  Future<int> _syncOfflineMessages() async {
    // Integration with OfflineMessageQueue
    // Returns number of messages queued for sync
    try {
      final hasQueued = await OfflineMessageQueue.hasQueued();
      final count = hasQueued ? (await OfflineMessageQueue.dequeueAll()).length : 0;
      debugPrint('[ConnectivityBloc] _syncOfflineMessages: $count messages in queue');
      return count;
    } catch (e) {
      debugPrint('[ConnectivityBloc] _syncOfflineMessages: ERROR - $e');
      return 0;
    }
  }

  Future<void> _recoverQueue() async {
    // Integration with OfflineMessageQueue
    // Process queued messages
    debugPrint('[ConnectivityBloc] _recoverQueue: START');
    try {
      // Process the queue
      final count = await _processQueue();
      add(QueueRecoveryCompleted(count));
      debugPrint('[ConnectivityBloc] _recoverQueue: COMPLETED - $count messages processed');
    } catch (e) {
      debugPrint('[ConnectivityBloc] _recoverQueue: ERROR - $e');
      add(QueueRecoveryCompleted(0));
    }
  }

  Future<int> _processQueue() async {
    // Process offline queue and return count of successfully sent messages
    debugPrint('[ConnectivityBloc] _processQueue: START');
    int processedCount = 0;
    
    try {
      // Check if there are any queued messages
      final hasQueued = await OfflineMessageQueue.hasQueued();
      if (!hasQueued) {
        debugPrint('[ConnectivityBloc] _processQueue: No messages to process');
        return 0;
      }
      
      // Get all queued messages
      final messages = await OfflineMessageQueue.dequeueAll();
      
      if (messages.isEmpty) {
        debugPrint('[ConnectivityBloc] _processQueue: No messages to process');
        return 0;
      }
      
      debugPrint('[ConnectivityBloc] _processQueue: Processing ${messages.length} messages');
      
      for (final entry in messages) {
        final key = entry.key;
        final payload = entry.value;
        
        try {
          // Check message type
          final type = payload['type'] as String?;
          
          if (type == 'message') {
            // Process message
            final text = payload['text'] as String?;
            final receiverId = payload['receiverId'] as String?;
            final currentUserId = payload['currentUserId'] as String?;
            final senderKeyVersion = payload['senderKeyVersion'] as String?;
            final receiverKeyVersion = payload['receiverKeyVersion'] as String?;
            final replyTo = payload['replyTo'] as Map<String, dynamic>?;
            
            if (text == null || receiverId == null || currentUserId == null) {
              debugPrint('[ConnectivityBloc] _processQueue: Invalid message payload');
              await OfflineMessageQueue.remove(key);
              continue;
            }
            
            debugPrint('[ConnectivityBloc] _processQueue: Sending message to $receiverId');
            
            // Load required keys for sending
            final receiverKeyResult = await ChatUtilService.loadReceiverPublicKey(receiverId);
            final senderKeyResult = await ChatUtilService.loadReceiverPublicKey(currentUserId);
            final privateKeyStr = await ChatUtilService.loadPrivateKey();
            
            if (receiverKeyResult?.publicKey == null || senderKeyResult?.publicKey == null || privateKeyStr == null) {
              debugPrint('[ConnectivityBloc] _processQueue: Keys not available, skipping message');
              continue;
            }
            
            // Send the message using SecureChatService
            await SecureChatService.sendSecureMessage(
              currentUserId: currentUserId,
              receiverId: receiverId,
              text: text,
              receiverPublicKey: receiverKeyResult!.publicKey,
              senderPublicKey: senderKeyResult!.publicKey,
              senderKeyVersion: senderKeyVersion ?? 'legacy',
              receiverKeyVersion: receiverKeyVersion ?? 'legacy',
              replyTo: replyTo,
            );
            
            // Remove from queue after successful send
            await OfflineMessageQueue.remove(key);
            processedCount++;
            debugPrint('[ConnectivityBloc] _processQueue: Message sent successfully');
            
          } else if (type == 'reaction') {
            // Process reaction
            final chatRoomId = payload['chatRoomId'] as String?;
            final messageId = payload['messageId'] as String?;
            final emoji = payload['emoji'] as String?;
            final userId = payload['userId'] as String?;
            final wasAdded = payload['wasAdded'] as bool?;
            
            if (chatRoomId == null || messageId == null || emoji == null || userId == null || wasAdded == null) {
              debugPrint('[ConnectivityBloc] _processQueue: Invalid reaction payload');
              await OfflineMessageQueue.remove(key);
              continue;
            }
            
            debugPrint('[ConnectivityBloc] _processQueue: Toggling reaction for message $messageId');
            
            await ChatUtilService.toggleReaction(
              chatRoomId: chatRoomId,
              messageId: messageId,
              emoji: emoji,
              userId: userId,
            );
            
            // Remove from queue after successful operation
            await OfflineMessageQueue.remove(key);
            processedCount++;
            debugPrint('[ConnectivityBloc] _processQueue: Reaction processed successfully');
          }
          
        } catch (e) {
          debugPrint('[ConnectivityBloc] _processQueue: Failed to process message - $e');
          // Don't remove from queue on failure - will be retried next time
        }
      }
      
      debugPrint('[ConnectivityBloc] _processQueue: COMPLETED - $processedCount/${messages.length} messages processed');
      return processedCount;
      
    } catch (e) {
      debugPrint('[ConnectivityBloc] _processQueue: ERROR - $e');
      return processedCount;
    }
  }

  @override
  Future<void> close() {
    _connectivitySubscription?.cancel();
    return super.close();
  }
}
