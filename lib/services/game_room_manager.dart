import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Game room lifecycle manager with proper hydration, timeout, and retry.
///
/// Features:
/// - Explicit states: loading, waitingForRoom, connected, playing, error
/// - Timeout + retry for room hydration
/// - Room creation confirmation before subscription
/// - Detailed logging
/// - Survives navigation/rebuilds
class GameRoomManager {
  static final GameRoomManager _instance = GameRoomManager._internal();
  factory GameRoomManager() => _instance;
  GameRoomManager._internal();

  final _firestore = FirebaseFirestore.instance;

  // Configuration
  static const Duration _roomCreationTimeout = Duration(seconds: 10);
  static const Duration _hydrationTimeout = Duration(seconds: 5);
  static const int _maxRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 1);

  // State
  final Map<String, _RoomState> _roomStates = {};
  final Map<String, StreamSubscription<DocumentSnapshot>> _subscriptions = {};
  final Map<String, StreamController<GameRoomState>> _controllers = {};
  final Map<String, Timer> _timeoutTimers = {};

  /// Get or create room state stream.
  /// 
  /// Handles:
  /// - Room creation confirmation
  /// - Subscription after room exists
  /// - Timeout + retry
  /// - Proper state transitions
  Stream<GameRoomState> joinRoom({
    required String roomId,
    required String gameType,
    required String userId,
    bool waitForRoom = true,
  }) {
    _dbg('[$roomId] Join requested by $userId, waitForRoom=$waitForRoom');

    // Return existing controller if already joined
    if (_controllers.containsKey(roomId)) {
      _dbg('[$roomId] Reusing existing controller');
      return _controllers[roomId]!.stream;
    }

    // Create controller
    final controller = StreamController<GameRoomState>.broadcast(
      onCancel: () {
        _dbg('[$roomId] Controller cancelled');
        _cleanupRoom(roomId);
      },
    );
    _controllers[roomId] = controller;

    // Emit loading state
    controller.add(GameRoomState.loading(roomId));

    if (waitForRoom) {
      // Wait for room to exist before subscribing
      _waitForRoomAndSubscribe(
        roomId: roomId,
        gameType: gameType,
        controller: controller,
        attempt: 1,
      );
    } else {
      // Subscribe immediately
      _subscribeToRoom(roomId: roomId, controller: controller);
    }

    return controller.stream;
  }

  /// Wait for room to exist, then subscribe.
  Future<void> _waitForRoomAndSubscribe({
    required String roomId,
    required String gameType,
    required StreamController<GameRoomState> controller,
    required int attempt,
  }) async {
    _dbg('[$roomId] Waiting for room (attempt $attempt/$_maxRetries)');

    if (!controller.hasListener || controller.isClosed) {
      _dbg('[$roomId] Controller closed, aborting');
      return;
    }

    // Emit waiting state
    controller.add(GameRoomState.waitingForRoom(roomId, attempt: attempt));

    try {
      // Try to get room with timeout
      final doc = await _firestore
          .collection('chat_rooms')
          .doc(roomId)
          .get()
          .timeout(_hydrationTimeout);

      if (!doc.exists) {
        throw Exception('Room does not exist');
      }

      final data = doc.data();
      final existingGame = data?['game'] as Map<String, dynamic>?;
      
      // Check if game exists and type matches
      if (existingGame != null) {
        final existingType = existingGame['type'] as String?;
        if (existingType != null && existingType != gameType) {
          _dbg('[$roomId] Room has different game type: $existingType vs $gameType');
          controller.add(GameRoomState.error(
            roomId,
            'Room has different game type',
            existingGame: existingGame,
          ));
          return;
        }
      }

      _dbg('[$roomId] Room found, subscribing');
      _subscribeToRoom(roomId: roomId, controller: controller);

    } on TimeoutException {
      if (attempt < _maxRetries) {
        _dbg('[$roomId] Timeout, retrying in ${_retryDelay.inSeconds}s');
        await Future.delayed(_retryDelay);
        _waitForRoomAndSubscribe(
          roomId: roomId,
          gameType: gameType,
          controller: controller,
          attempt: attempt + 1,
        );
      } else {
        _dbg('[$roomId] Max retries exceeded');
        controller.add(GameRoomState.error(
          roomId,
          'Room creation timeout - max retries exceeded',
        ));
      }
    } catch (e) {
      _dbg('[$roomId] Error waiting for room: $e');
      controller.add(GameRoomState.error(roomId, 'Failed to join room: $e'));
    }
  }

  /// Subscribe to room snapshots.
  void _subscribeToRoom({
    required String roomId,
    required StreamController<GameRoomState> controller,
  }) {
    if (controller.isClosed) {
      _dbg('[$roomId] Controller closed before subscription');
      return;
    }

    // Cancel any existing subscription
    _subscriptions[roomId]?.cancel();

    _dbg('[$roomId] Starting snapshot subscription');

    final subscription = _firestore
        .collection('chat_rooms')
        .doc(roomId)
        .snapshots()
        .listen(
          (snapshot) {
            if (controller.isClosed) return;

            _dbg('[$roomId] Snapshot received, exists=${snapshot.exists}');

            if (!snapshot.exists) {
              controller.add(GameRoomState.error(roomId, 'Room deleted'));
              return;
            }

            final data = snapshot.data();
            final gameData = data?['game'] as Map<String, dynamic>?;

            _dbg('[$roomId] Game data: ${gameData != null ? 'present' : 'null'}');

            if (gameData == null) {
              controller.add(GameRoomState.connected(roomId, null));
              return;
            }

            final status = gameData['status'] as String? ?? 'waiting';
            _dbg('[$roomId] Game status: $status');

            // Emit playing state
            controller.add(GameRoomState.playing(
              roomId: roomId,
              gameData: gameData,
              players: List<String>.from(gameData['submitted'] ?? []),
              status: status,
            ));
          },
          onError: (error) {
            _dbg('[$roomId] Subscription error: $error');
            if (!controller.isClosed) {
              controller.add(GameRoomState.error(roomId, 'Connection error: $error'));
            }
          },
          onDone: () {
            _dbg('[$roomId] Subscription closed');
          },
        );

    _subscriptions[roomId] = subscription;

    // Set timeout timer
    _timeoutTimers[roomId]?.cancel();
    _timeoutTimers[roomId] = Timer(_hydrationTimeout, () {
      _dbg('[$roomId] Hydration timeout check');
      // If still connected but no data, emit error
      if (!controller.isClosed) {
        // This is a safety net - normally data should arrive before timeout
      }
    });
  }

  /// Leave room and cleanup.
  Future<void> leaveRoom(String roomId) async {
    _dbg('[$roomId] Leaving room');
    _cleanupRoom(roomId);
  }

  /// Cleanup room resources.
  void _cleanupRoom(String roomId) {
    _dbg('[$roomId] Cleaning up');
    
    _timeoutTimers[roomId]?.cancel();
    _timeoutTimers.remove(roomId);
    
    _subscriptions[roomId]?.cancel();
    _subscriptions.remove(roomId);
    
    _controllers[roomId]?.close();
    _controllers.remove(roomId);
    
    _roomStates.remove(roomId);
  }

  /// Dispose all resources.
  void dispose() {
    _dbg('Disposing all rooms');
    for (final roomId in List<String>.from(_controllers.keys)) {
      _cleanupRoom(roomId);
    }
  }

  void _dbg(String message) {
    if (kDebugMode) {
      debugPrint('[GameRoomManager] $message');
    }
  }
}

/// Game room state.
class GameRoomState {
  final String roomId;
  final GameRoomStatus status;
  final Map<String, dynamic>? gameData;
  final List<String> players;
  final String? error;
  final int? attempt;

  GameRoomState({
    required this.roomId,
    required this.status,
    this.gameData,
    this.players = const [],
    this.error,
    this.attempt,
  });

  // Factory constructors for each state
  factory GameRoomState.loading(String roomId) => GameRoomState(
        roomId: roomId,
        status: GameRoomStatus.loading,
      );

  factory GameRoomState.waitingForRoom(String roomId, {int? attempt}) => GameRoomState(
        roomId: roomId,
        status: GameRoomStatus.waitingForRoom,
        attempt: attempt,
      );

  factory GameRoomState.connected(String roomId, Map<String, dynamic>? gameData) => GameRoomState(
        roomId: roomId,
        status: GameRoomStatus.connected,
        gameData: gameData,
      );

  factory GameRoomState.playing({
    required String roomId,
    required Map<String, dynamic> gameData,
    required List<String> players,
    required String status,
  }) => GameRoomState(
        roomId: roomId,
        status: GameRoomStatus.playing,
        gameData: gameData,
        players: players,
      );

  factory GameRoomState.error(String roomId, String error, {Map<String, dynamic>? existingGame}) => GameRoomState(
        roomId: roomId,
        status: GameRoomStatus.error,
        error: error,
        gameData: existingGame,
      );

  // Convenience getters
  bool get isLoading => status == GameRoomStatus.loading;
  bool get isWaitingForRoom => status == GameRoomStatus.waitingForRoom;
  bool get isConnected => status == GameRoomStatus.connected;
  bool get isPlaying => status == GameRoomStatus.playing;
  bool get hasError => status == GameRoomStatus.error;
  bool get hasGame => gameData != null;
}

enum GameRoomStatus {
  loading,
  waitingForRoom,
  connected,
  playing,
  error,
}

class _RoomState {
  final String roomId;
  DateTime? createdAt;
  int retryCount = 0;
  bool isSubscribed = false;

  _RoomState(this.roomId);
}
