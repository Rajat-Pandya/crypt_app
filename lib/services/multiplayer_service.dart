import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'game_service.dart';

/// Centralized multiplayer service with proper ownership and lifecycle management.
///
/// ARCHITECTURE:
/// - This service is the SOLE OWNER of Firestore game streams
/// - GameBloc and screens should use this service, NOT create direct subscriptions
/// - Proper dispose lifecycle: leaveRoom() before closing Bloc/screen
///
/// Features:
/// - Singleton pattern with centralized dispose ownership
/// - Deduplicated listener management (prevents duplicate Firestore listeners)
/// - Stable reconnect recovery (restores state after network loss)
/// - Transaction-safe move updates (prevents race conditions)
/// - Move caching (prevents duplicate move execution)
/// - Connection state tracking (online/offline/reconnecting)
class MultiplayerService {
  // ==========================================================================
  // SINGLETON PATTERN
  // ==========================================================================

  static final MultiplayerService _instance = MultiplayerService._internal();
  factory MultiplayerService() => _instance;
  MultiplayerService._internal();

  static final _firestore = FirebaseFirestore.instance;

  // ==========================================================================
  // STATE MANAGEMENT
  // ==========================================================================

  /// Connection state tracking with stream
  MultiplayerConnectionState _connectionState = MultiplayerConnectionState.waiting;
  MultiplayerConnectionState get connectionState => _connectionState;
  
  /// Connection state broadcast stream for Bloc subscriptions
  final _connectionStateController = StreamController<MultiplayerConnectionState>.broadcast();
  Stream<MultiplayerConnectionState> get connectionStateStream => _connectionStateController.stream;

  /// Current room being monitored (null if not in a game)
  String? _currentRoomId;
  String? get currentRoomId => _currentRoomId;

  /// Current user ID
  String? _currentUserId;
  String? get currentUserId => _currentUserId;

  /// Whether service is initialized
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // ==========================================================================
  // STREAM MANAGEMENT (Deduplicated)
  // ==========================================================================

  /// Centralized stream cache - ONE stream per room
  static final Map<String, Stream<DocumentSnapshot>> _streamCache = {};

  /// Active subscriptions tracked by room
  static final Map<String, StreamSubscription<DocumentSnapshot>> _subscriptions = {};
  
  /// Controller cache - ONE controller per room (✅ FIX: prevent duplicate controllers)
  static final Map<String, StreamController<Map<String, dynamic>?>> _controllerCache = {};

  /// Last snapshot timestamp per room (for reconnect detection)
  static final Map<String, DateTime> _lastSnapshotTime = {};

  /// Pending move cache (prevents duplicate execution)
  static final Set<String> _pendingMoves = {};

  /// Completed moves log (prevents replay after reconnect)
  static final Map<String, DateTime> _completedMoves = {};
  static const Duration _moveLogRetention = Duration(minutes: 5);

  // ==========================================================================
  // RECONNECT RECOVERY
  // ==========================================================================

  /// Reconnect state
  bool _isReconnecting = false;
  bool get isReconnecting => _isReconnecting;

  /// Queue of pending operations during offline state
  final List<_PendingOperation> _pendingOperations = [];

  /// Reconnect completer (for awaiting reconnect)
  Completer<void>? _reconnectCompleter;

  // ==========================================================================
  // LISTENERS
  // ==========================================================================

  /// Game state change listeners
  final Map<String, List<void Function(Map<String, dynamic>?)>> _gameStateListeners = {};

  /// Connection state listeners
  final List<void Function(MultiplayerConnectionState)> _connectionListeners = [];

  // ==========================================================================
  // INITIALIZATION
  // ==========================================================================

  /// Initialize the multiplayer service
  ///
  /// Call this once when app starts. Sets up connection monitoring.
  Future<void> initialize(String userId) async {
    if (_isInitialized) {
      _dbg('Already initialized, skipping');
      return;
    }

    _currentUserId = userId;
    _isInitialized = true;
    _connectionState = MultiplayerConnectionState.active;
    _connectionStateController.add(_connectionState);

    _dbg('MultiplayerService initialized for user: $userId');
  }

  // ==========================================================================
  // ROOM MANAGEMENT
  // ==========================================================================

  /// Join a multiplayer room
  ///
  /// Centralized ownership - this service owns the Firestore listener
  /// Returns a unique stream that deduplicates all listeners
  /// 
  /// IMPORTANT: Call [leaveRoom] when done to prevent memory leaks
  Stream<Map<String, dynamic>?> joinRoom(String roomId) {
    _dbg('Joining room: $roomId');
    _currentRoomId = roomId;

    // Update connection state
    _connectionState = MultiplayerConnectionState.active;
    _connectionStateController.add(_connectionState);

    // Deduplicated stream - returns existing if already listening
    return _getGameStateStream(roomId);
  }

  /// Leave current room
  ///
  /// Properly disposes listeners and clears state
  Future<void> leaveRoom() async {
    if (_currentRoomId == null) {
      _dbg('Not in any room, nothing to leave');
      return;
    }

    final roomId = _currentRoomId!;
    _dbg('Leaving room: $roomId');

    // Cancel subscription
    await _subscriptions[roomId]?.cancel();
    _subscriptions.remove(roomId);
    
    // ✅ FIX: Close and remove controller
    if (_controllerCache.containsKey(roomId)) {
      final controller = _controllerCache[roomId]!;
      if (!controller.isClosed) {
        await controller.close();
        _dbg('Closed controller for room: $roomId');
      }
      _controllerCache.remove(roomId);
    }
    
    // Remove stream cache to force fresh connection next time
    _streamCache.remove(roomId);

    // Clear pending operations for this room
    _pendingOperations.removeWhere((op) => op.roomId == roomId);

    // Clear listeners for this room
    _gameStateListeners.remove(roomId);
    
    // Clear last snapshot time
    _lastSnapshotTime.remove(roomId);

    _currentRoomId = null;
    
    _dbg('Successfully left room: $roomId');
  }

  // ==========================================================================
  // GAME STATE STREAM (Deduplicated)
  // ==========================================================================

  /// Gets or creates a deduplicated game state stream
  /// 
  /// ✅ FIX: Returns cached controller stream if already exists
  Stream<Map<String, dynamic>?> _getGameStateStream(String roomId) {
    _dbg('[_getGameStateStream] room=$roomId');
    
    // ✅ FIX: Return cached controller if exists and not closed
    if (_controllerCache.containsKey(roomId)) {
      final cachedController = _controllerCache[roomId]!;
      if (!cachedController.isClosed) {
        _dbg('[_getGameStateStream] returning CACHED stream for room $roomId');
        return cachedController.stream;
      } else {
        _dbg('[_getGameStateStream] cached controller closed, removing');
        _controllerCache.remove(roomId);
      }
    }
    
    _dbg('[_getGameStateStream] creating NEW controller for room $roomId');

    // Create controller that manages the subscription
    final controller = StreamController<Map<String, dynamic>?>.broadcast();
    
    // Cache the controller
    _controllerCache[roomId] = controller;

    // Get or create the Firestore stream
    final stream = _streamCache.putIfAbsent(
      roomId,
      () => _firestore.collection('chat_rooms').doc(roomId).snapshots(),
    );

    // Subscribe only if not already subscribed
    if (!_subscriptions.containsKey(roomId)) {
      _subscriptions[roomId] = stream.listen(
        (snapshot) {
          _lastSnapshotTime[roomId] = DateTime.now();

          if (!snapshot.exists) {
            _notifyGameStateListeners(roomId, null);
            return;
          }

          final data = snapshot.data() as Map<String, dynamic>?;
          final gameData = data?['game'] as Map<String, dynamic>?;

          _notifyGameStateListeners(roomId, gameData);
        },
        onError: (error) {
          _dbg('Stream error for room $roomId: $error');
          _handleConnectionError(roomId);
        },
        onDone: () {
          _dbg('Stream closed for room $roomId');
          _subscriptions.remove(roomId);
        },
      );
    }

    // Add listener to receive updates
    void listener(Map<String, dynamic>? data) {
      if (!controller.isClosed) {
        controller.add(data);
      }
    }

    _addGameStateListener(roomId, listener);

    // Clean up when controller is closed
    controller.onCancel = () {
      _dbg('[_getGameStateStream] controller onCancel for room $roomId');
      _removeGameStateListener(roomId, listener);
    };
    
    // Clean up when controller is closed (complete)
    controller.done.then((_) {
      _dbg('[_getGameStateStream] controller done for room $roomId, cleaning up');
      _controllerCache.remove(roomId);
    });

    return controller.stream;
  }

  // ==========================================================================
  // MOVE EXECUTION (Transaction-Safe)
  // ==========================================================================

  /// Execute a move with transaction safety
  ///
  /// Features:
  /// - Duplicate prevention via move cache
  /// - Transaction execution (atomic)
  /// - Offline queue (executes when back online)
  /// - Reconnect recovery (resumes after network loss)
  Future<bool> executeMove({
    required String roomId,
    required int position,
    required String playerId,
    Map<String, dynamic>? extraData,
  }) async {
    final moveId = '${roomId}_${playerId}_${position}_$_currentUserId';

    // GUARD: Prevent duplicate moves
    if (_pendingMoves.contains(moveId)) {
      _dbg('Move already pending: $moveId');
      return false;
    }

    if (_completedMoves.containsKey(moveId)) {
      final completedAt = _completedMoves[moveId]!;
      if (DateTime.now().difference(completedAt) < _moveLogRetention) {
        _dbg('Move recently completed: $moveId');
        return false;
      }
    }

    // Check connection state
    if (_connectionState == MultiplayerConnectionState.done) {
      // Queue for later execution
      _pendingOperations.add(_PendingOperation(
        roomId: roomId,
        type: _OperationType.move,
        data: {
          'position': position,
          'playerId': playerId,
          'extraData': extraData,
        },
      ));
      _dbg('Move queued for reconnect: $moveId');
      return true;
    }

    _pendingMoves.add(moveId);

    try {
      _dbg('Executing move: $moveId');

      await GameService.makeMove(
        roomId: roomId,
        index: position,
        currentUserId: playerId,
      );

      _completedMoves[moveId] = DateTime.now();
      _dbg('Move executed successfully: $moveId');
      return true;
    } catch (e) {
      _dbg('Move execution failed: $e');
      return false;
    } finally {
      _pendingMoves.remove(moveId);
      _cleanupCompletedMoves();
    }
  }

  /// Execute a Connect Four move with transaction safety
  Future<bool> executeConnectFourMove({
    required String roomId,
    required int column,
    required String playerId,
  }) async {
    final moveId = '${roomId}_${playerId}_col$column';

    if (_pendingMoves.contains(moveId)) {
      _dbg('Connect Four move already pending: $moveId');
      return false;
    }

    if (_completedMoves.containsKey(moveId)) {
      final completedAt = _completedMoves[moveId]!;
      if (DateTime.now().difference(completedAt) < _moveLogRetention) {
        _dbg('Connect Four move recently completed: $moveId');
        return false;
      }
    }

    _pendingMoves.add(moveId);

    try {
      _dbg('Executing Connect Four move: $moveId');

      final success = await GameService.makeConnectFourMove(
        roomId: roomId,
        column: column,
        currentUserId: playerId,
      );

      if (success) {
        _completedMoves[moveId] = DateTime.now();
      }

      return success;
    } catch (e) {
      _dbg('Connect Four move execution failed: $e');
      return false;
    } finally {
      _pendingMoves.remove(moveId);
      _cleanupCompletedMoves();
    }
  }

  // ==========================================================================
  // RECONNECT RECOVERY
  // ==========================================================================

  /// Handle connection loss
  void _handleConnectionError(String roomId) {
    if (_connectionState != MultiplayerConnectionState.waiting) {
      _connectionState = MultiplayerConnectionState.waiting;
      _isReconnecting = true;
      _reconnectCompleter = Completer<void>();

      _connectionStateController.add(_connectionState);
      _notifyConnectionListeners(MultiplayerConnectionState.waiting);

      // Attempt reconnect
      _attemptReconnect(roomId);
    }
  }

  /// Attempt to reconnect
  Future<void> _attemptReconnect(String roomId) async {
    _dbg('Attempting reconnect for room: $roomId');
    
    // Notify listeners of reconnect attempt
    _connectionState = MultiplayerConnectionState.waiting;
    _connectionStateController.add(_connectionState);

    int attempts = 0;
    const maxAttempts = 5;
    const delays = [1, 2, 5, 10, 30]; // seconds

    while (attempts < maxAttempts) {
      await Future.delayed(Duration(seconds: delays[attempts]));
      attempts++;

      try {
        // Test connection
        await _firestore.collection('chat_rooms').doc(roomId).get();

        // Reconnection successful
        _connectionState = MultiplayerConnectionState.active;
        _isReconnecting = false;

        // Restore subscription
        await _subscriptions[roomId]?.cancel();
        _subscriptions.remove(roomId);

        // Rejoin room to restore stream
        joinRoom(roomId);

        // Execute pending operations
        await _executePendingOperations(roomId);

        _reconnectCompleter?.complete();
        _reconnectCompleter = null;

        _connectionStateController.add(_connectionState);
        _notifyConnectionListeners(MultiplayerConnectionState.active);
        _dbg('Reconnected successfully after $attempts attempts');
        return;
      } catch (e) {
        _dbg('Reconnect attempt $attempts failed: $e');
      }
    }

    _dbg('Max reconnect attempts reached');
    _connectionState = MultiplayerConnectionState.done;
    _connectionStateController.add(_connectionState);
    _reconnectCompleter?.completeError(Exception('Max reconnect attempts reached'));
    _reconnectCompleter = null;
  }

  /// Execute pending operations after reconnect
  Future<void> _executePendingOperations(String roomId) async {
    final operations = _pendingOperations
        .where((op) => op.roomId == roomId)
        .toList();

    if (operations.isEmpty) return;

    _dbg('Executing ${operations.length} pending operations');

    for (final op in operations) {
      try {
        switch (op.type) {
          case _OperationType.move:
            await executeMove(
              roomId: op.roomId,
              position: op.data['position'],
              playerId: op.data['playerId'],
              extraData: op.data['extraData'],
            );
            break;
          case _OperationType.reset:
            await GameService.resetGame(roomId: op.roomId);
            break;
        }
      } catch (e) {
        _dbg('Failed to execute pending operation: $e');
      }
    }

    _pendingOperations.removeWhere((op) => op.roomId == roomId);
  }

  /// Wait for reconnection
  Future<void> waitForReconnect() async {
    if (!_isReconnecting) return;
    if (_reconnectCompleter == null) return;
    return _reconnectCompleter!.future;
  }

  // ==========================================================================
  // DISPOSE (Centralized Ownership)
  // ==========================================================================

  /// Centralized dispose - call this from app lifecycle or logout
  ///
  /// Properly cleans up ALL resources owned by this service
  Future<void> dispose() async {
    _dbg('Disposing MultiplayerService');

    // Cancel all subscriptions
    for (final entry in _subscriptions.entries) {
      await entry.value.cancel();
    }
    _subscriptions.clear();

    // Clear streams
    _streamCache.clear();

    // Clear listeners
    _gameStateListeners.clear();
    _connectionListeners.clear();
    
    // Close connection state controller
    await _connectionStateController.close();

    // Clear state
    _pendingMoves.clear();
    _completedMoves.clear();
    _pendingOperations.clear();

    _currentRoomId = null;
    _isInitialized = false;
    _isReconnecting = false;
    _connectionState = MultiplayerConnectionState.done;

    _dbg('MultiplayerService disposed');
  }

  // ==========================================================================
  // LISTENER MANAGEMENT
  // ==========================================================================

  void _addGameStateListener(String roomId, void Function(Map<String, dynamic>?) listener) {
    _gameStateListeners.putIfAbsent(roomId, () => []);
    _gameStateListeners[roomId]!.add(listener);
  }

  void _removeGameStateListener(String roomId, void Function(Map<String, dynamic>?) listener) {
    _gameStateListeners[roomId]?.remove(listener);
    if (_gameStateListeners[roomId]?.isEmpty ?? false) {
      _gameStateListeners.remove(roomId);
    }
  }

  void _notifyGameStateListeners(String roomId, Map<String, dynamic>? data) {
    final listeners = _gameStateListeners[roomId];
    if (listeners == null) {
      _dbg('[STATE] No listeners for room $roomId');
      return;
    }
    
    final listenerCount = listeners.length;
    _dbg('[STATE] Notifying $listenerCount listeners for room $roomId');
    
    if (data != null) {
      final status = data['status'] as String?;
      final submitted = data['submitted'] as List?;
      final numberSetter = data['numberSetter'] as String?;
      final guesser = data['guesser'] as String?;
      _dbg('[STATE]   Game data: status=$status, submitted=${submitted?.length}, setter=$numberSetter, guesser=$guesser');
    } else {
      _dbg('[STATE]   Game data: null (game deleted or no game)');
    }

    // Create a copy to avoid modification during iteration
    for (final listener in List.of(listeners)) {
      try {
        listener(data);
      } catch (e) {
        _dbg('Error notifying listener: $e');
      }
    }
    
    _dbg('[STATE] Notification complete for room $roomId');
  }

  /// Add connection state listener
  void addConnectionListener(void Function(MultiplayerConnectionState) listener) {
    _connectionListeners.add(listener);
  }

  /// Remove connection state listener
  void removeConnectionListener(void Function(MultiplayerConnectionState) listener) {
    _connectionListeners.remove(listener);
  }

  void _notifyConnectionListeners(MultiplayerConnectionState state) {
    for (final listener in List.of(_connectionListeners)) {
      try {
        listener(state);
      } catch (e) {
        _dbg('Error notifying connection listener: $e');
      }
    }
  }

  // ==========================================================================
  // UTILITIES
  // ==========================================================================

  void _cleanupCompletedMoves() {
    final now = DateTime.now();
    _completedMoves.removeWhere(
      (id, time) => now.difference(time) > _moveLogRetention,
    );
  }

  void _dbg(String message) {
    assert(() {
      debugPrint('[MultiplayerService] $message');
      return true;
    }());
  }
}

// ============================================================================
// PUBLIC TYPES
// ============================================================================

/// Connection state for multiplayer service
/// 
/// This is a custom enum to avoid conflict with dart:async's ConnectionState
enum MultiplayerConnectionState {
  /// Initial state, waiting for connection
  waiting,
  
  /// Connected and active
  active,
  
  /// Connection closed
  done,
}

// ============================================================================
// INTERNAL TYPES
// ============================================================================

enum _OperationType { move, reset }

class _PendingOperation {
  final String roomId;
  final _OperationType type;
  final Map<String, dynamic> data;

  _PendingOperation({
    required this.roomId,
    required this.type,
    required this.data,
  });
}
