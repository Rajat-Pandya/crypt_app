import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';


import '../services/multiplayer_service.dart';

// ============================================================================
// EVENTS
// ============================================================================

/// Base class for all game events
abstract class GameEvent {
  const GameEvent();
}

/// Initialize game system
class GameInitialized extends GameEvent {
  final String roomId;
  final String currentUserId;
  
  const GameInitialized({
    required this.roomId,
    required this.currentUserId,
  });
}

/// Load game state from Firestore
class LoadGameState extends GameEvent {
  const LoadGameState();
}

/// Start a new game
class StartGame extends GameEvent {
  final String gameType;
  final Map<String, dynamic>? settings;
  
  const StartGame(this.gameType, {this.settings});
}

/// Make a move in the game
class MakeMove extends GameEvent {
  final int position;
  final String playerId;
  final Map<String, dynamic>? extraData;
  
  const MakeMove({
    required this.position,
    required this.playerId,
    this.extraData,
  });
}

/// Update game state from external source (e.g., Firestore listener)
class GameStateUpdated extends GameEvent {
  final Map<String, dynamic> gameData;
  
  const GameStateUpdated(this.gameData);
}

/// End current game
class EndGame extends GameEvent {
  final String? winnerId;
  final String? reason;
  
  const EndGame({this.winnerId, this.reason});
}

/// Reset game to initial state
class ResetGame extends GameEvent {
  const ResetGame();
}

/// Player joined the game
class PlayerJoined extends GameEvent {
  final String playerId;
  final String playerName;
  
  const PlayerJoined(this.playerId, this.playerName);
}

/// Player left the game
class PlayerLeft extends GameEvent {
  final String playerId;
  
  const PlayerLeft(this.playerId);
}

/// Toggle game visibility/mode
class ToggleGameMode extends GameEvent {
  final bool isGameActive;
  
  const ToggleGameMode(this.isGameActive);
}

/// Game error occurred
class GameErrorOccurred extends GameEvent {
  final String error;
  final String? operation;
  
  const GameErrorOccurred(this.error, {this.operation});
}

// ============================================================================
// STATE
// ============================================================================

/// Represents a game player
class GamePlayer {
  final String id;
  final String name;
  final String symbol;
  final bool isOnline;
  final DateTime? lastActive;

  const GamePlayer({
    required this.id,
    required this.name,
    required this.symbol,
    this.isOnline = true,
    this.lastActive,
  });

  GamePlayer copyWith({
    String? id,
    String? name,
    String? symbol,
    bool? isOnline,
    DateTime? lastActive,
  }) {
    return GamePlayer(
      id: id ?? this.id,
      name: name ?? this.name,
      symbol: symbol ?? this.symbol,
      isOnline: isOnline ?? this.isOnline,
      lastActive: lastActive ?? this.lastActive,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'symbol': symbol,
    'isOnline': isOnline,
    'lastActive': lastActive?.toIso8601String(),
  };

  factory GamePlayer.fromJson(Map<String, dynamic> json) {
    return GamePlayer(
      id: json['id'] as String,
      name: json['name'] as String,
      symbol: json['symbol'] as String,
      isOnline: json['isOnline'] as bool? ?? true,
      lastActive: json['lastActive'] != null
          ? DateTime.parse(json['lastActive'] as String)
          : null,
    );
  }
}

/// Represents the game state
class GameState {
  final bool isInitialized;
  final bool isLoading;
  final bool isGameActive;
  final String? gameType;
  final String? currentPlayerId;
  final String? winnerId;
  final bool isDraw;
  final List<String?> board;
  final List<GamePlayer> players;
  final Map<String, dynamic> gameData;
  final String? error;
  final DateTime? startTime;
  final DateTime? endTime;
  final int moveCount;
  final bool isMyTurn;

  // Game settings
  final Map<String, dynamic>? settings;

  const GameState({
    this.isInitialized = false,
    this.isLoading = false,
    this.isGameActive = false,
    this.gameType,
    this.currentPlayerId,
    this.winnerId,
    this.isDraw = false,
    this.board = const [],
    this.players = const [],
    this.gameData = const {},
    this.error,
    this.startTime,
    this.endTime,
    this.moveCount = 0,
    this.isMyTurn = false,
    this.settings,
  });

  GameState copyWith({
    bool? isInitialized,
    bool? isLoading,
    bool? isGameActive,
    String? gameType,
    String? currentPlayerId,
    String? winnerId,
    bool? isDraw,
    List<String?>? board,
    List<GamePlayer>? players,
    Map<String, dynamic>? gameData,
    String? error,
    DateTime? startTime,
    DateTime? endTime,
    int? moveCount,
    bool? isMyTurn,
    Map<String, dynamic>? settings,
  }) {
    return GameState(
      isInitialized: isInitialized ?? this.isInitialized,
      isLoading: isLoading ?? this.isLoading,
      isGameActive: isGameActive ?? this.isGameActive,
      gameType: gameType ?? this.gameType,
      currentPlayerId: currentPlayerId ?? this.currentPlayerId,
      winnerId: winnerId,
      isDraw: isDraw ?? this.isDraw,
      board: board ?? this.board,
      players: players ?? this.players,
      gameData: gameData ?? this.gameData,
      error: error ?? this.error,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      moveCount: moveCount ?? this.moveCount,
      isMyTurn: isMyTurn ?? this.isMyTurn,
      settings: settings ?? this.settings,
    );
  }

  /// Get current player
  GamePlayer? get currentPlayer {
    try {
      return players.firstWhere((p) => p.id == currentPlayerId);
    } catch (_) {
      return null;
    }
  }

  /// Get player by ID
  GamePlayer? getPlayer(String id) {
    try {
      return players.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get player symbol
  String? getPlayerSymbol(String id) {
    return getPlayer(id)?.symbol;
  }

  /// Check if game is over
  bool get isGameOver => winnerId != null || isDraw;

  /// Check if position is valid
  bool isValidMove(int position) {
    if (!isGameActive || isGameOver) return false;
    if (position < 0 || position >= board.length) return false;
    return board[position] == null;
  }

  /// Get winning positions (if any) for the current game type
  List<int>? get winningPositions {
    switch (gameType) {
      case 'tic_tac_toe':
        return _calculateTicTacToeWinningPositions();
      case 'connectfour':
        return _getConnectFourWinningPositions();
      default:
        return null;
    }
  }
  
  /// Calculate Tic Tac Toe winning positions locally
  List<int>? _calculateTicTacToeWinningPositions() {
    const winningCombinations = [
      [0, 1, 2], [3, 4, 5], [6, 7, 8], // Rows
      [0, 3, 6], [1, 4, 7], [2, 5, 8], // Columns
      [0, 4, 8], [2, 4, 6], // Diagonals
    ];

    for (final combo in winningCombinations) {
      final a = board[combo[0]];
      final b = board[combo[1]];
      final c = board[combo[2]];
      
      if (a != null && a == b && a == c) {
        return combo;
      }
    }
    return null;
  }
  
  /// Get Connect Four winning positions from server data
  List<int>? _getConnectFourWinningPositions() {
    final winningCells = gameData['winningCells'];
    if (winningCells is List && winningCells.isNotEmpty) {
      return winningCells.cast<int>().toList();
    }
    return null;
  }

  /// Get available moves
  List<int> get availableMoves {
    final moves = <int>[];
    for (int i = 0; i < board.length; i++) {
      if (board[i] == null) moves.add(i);
    }
    return moves;
  }
}

// ============================================================================
// BLOC
// ============================================================================

/// BLoC for managing game state and operations
/// 
/// Now uses MultiplayerService for centralized stream ownership and lifecycle:
/// - Stream management: MultiplayerService owns and disposes Firestore streams
/// - Reconnect recovery: Buffered operations replay on network restoration  
/// - Deduplication: Move IDs prevent duplicate execution
/// - Transaction safety: Firestore transactions prevent race conditions
/// 
/// Handles:
/// - Game initialization and setup
/// - Move validation and execution
/// - Game state synchronization via MultiplayerService
/// - Player management
class GameBloc extends Bloc<GameEvent, GameState> {
  StreamSubscription<Map<String, dynamic>?>? _gameStateSubscription;
  StreamSubscription<MultiplayerConnectionState>? _connectionSubscription;
  
  // MultiplayerService reference - centralized stream ownership
  final MultiplayerService _multiplayerService = MultiplayerService();
  
  // Reconnect recovery state
  final List<_PendingGameOperation> _pendingOperations = [];
  bool _isReconnecting = false;
  
  // Throttling to prevent rapid move submission
  DateTime? _lastMoveTime;
  static const _minMoveInterval = Duration(milliseconds: 300);
  
  String? _roomId;
  String? _currentUserId;

  GameBloc() : super(const GameState()) {
    on<GameInitialized>(_onInitialized);
    on<LoadGameState>(_onLoadGameState);
    on<StartGame>(_onStartGame);
    on<MakeMove>(_onMakeMove);
    on<GameStateUpdated>(_onGameStateUpdated);
    on<EndGame>(_onEndGame);
    on<ResetGame>(_onResetGame);
    on<PlayerJoined>(_onPlayerJoined);
    on<PlayerLeft>(_onPlayerLeft);
    on<ToggleGameMode>(_onToggleGameMode);
    on<GameErrorOccurred>(_onGameError);
  }

  // ==========================================================================
  // Event Handlers
  // ==========================================================================

  Future<void> _onInitialized(
    GameInitialized event,
    Emitter<GameState> emit,
  ) async {
    _roomId = event.roomId;
    _currentUserId = event.currentUserId;
    
    // Initialize MultiplayerService for this user
    await _multiplayerService.initialize(event.currentUserId);
    
    // Listen to MultiplayerService connection state
    _connectionSubscription = _multiplayerService
        .connectionStateStream
        .listen(_onConnectionStateChanged);
    
    emit(state.copyWith(isInitialized: true));
    
    // Start listening to game state via MultiplayerService
    await _subscribeToGameState(event.roomId);
  }

  Future<void> _onLoadGameState(
    LoadGameState event,
    Emitter<GameState> emit,
  ) async {
    if (_roomId == null) return;
    
    emit(state.copyWith(isLoading: true));
    
    try {
      final doc = await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(_roomId)
          .get();
      
      if (doc.exists && doc.data()?['game'] != null) {
        final gameData = doc.data()!['game'] as Map<String, dynamic>;
        add(GameStateUpdated(gameData));
      }
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Failed to load game: $e',
      ));
    }
  }

  Future<void> _onStartGame(
    StartGame event,
    Emitter<GameState> emit,
  ) async {
    if (_roomId == null || _currentUserId == null) return;
    
    emit(state.copyWith(isLoading: true));
    
    try {
      // Initialize game based on type
      final boardSize = event.gameType == 'tic_tac_toe' ? 9 : 9;
      final board = List<String?>.filled(boardSize, null);
      
      final gameData = {
        'type': event.gameType,
        'isActive': true,
        'board': board,
        'currentPlayerId': _currentUserId,
        'players': [
          {
            'id': _currentUserId,
            'name': 'Player 1',
            'symbol': 'X',
            'isOnline': true,
          },
        ],
        'moveCount': 0,
        'startTime': DateTime.now().toIso8601String(),
        'settings': event.settings ?? {},
      };
      
      // Update Firestore
      await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(_roomId)
          .update({'game': gameData});
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Failed to start game: $e',
      ));
    }
  }

  Future<void> _onMakeMove(
    MakeMove event,
    Emitter<GameState> emit,
  ) async {
    if (_roomId == null || !state.isGameActive || state.isGameOver) return;
    
    // Throttle rapid moves (prevent accidental double-tap)
    if (_lastMoveTime != null) {
      final elapsed = DateTime.now().difference(_lastMoveTime!);
      if (elapsed < _minMoveInterval) {
        _dbg('Move throttled - too rapid (${elapsed.inMilliseconds}ms)');
        return;
      }
    }
    _lastMoveTime = DateTime.now();
    
    // Validate move
    if (!state.isValidMove(event.position)) {
      emit(state.copyWith(error: 'Invalid move'));
      return;
    }
    
    // Check if it's player's turn
    if (state.currentPlayerId != event.playerId) {
      emit(state.copyWith(error: 'Not your turn'));
      return;
    }
    
    // Check if we're reconnecting - queue move for later
    if (_isReconnecting) {
      _pendingOperations.add(_PendingGameOperation(
        type: _GameOperationType.move,
        roomId: _roomId!,
        data: {
          'position': event.position,
          'playerId': event.playerId,
          'extraData': event.extraData,
        },
      ));
      _dbg('Move queued for reconnect: pos=${event.position}');
      return;
    }
    
    try {
      // Use MultiplayerService for transaction-safe move execution
      // This prevents duplicate execution and handles race conditions
      final success = await _multiplayerService.executeMove(
        roomId: _roomId!,
        position: event.position,
        playerId: event.playerId,
        extraData: event.extraData,
      );
      
      if (!success) {
        _dbg('Move rejected by MultiplayerService (duplicate or invalid)');
        return;
      }
      
      _dbg('Move executed successfully: pos=${event.position}');
    } catch (e) {
      _dbg('Move failed: $e');
      emit(state.copyWith(error: 'Failed to make move: $e'));
    }
  }

  void _onGameStateUpdated(
    GameStateUpdated event,
    Emitter<GameState> emit,
  ) {
    final data = event.gameData;
    
    // Parse players
    final playersData = data['players'] as List<dynamic>? ?? [];
    final players = playersData
        .map((p) => GamePlayer.fromJson(p as Map<String, dynamic>))
        .toList();
    
    // Parse board
    final boardData = data['board'] as List<dynamic>? ?? [];
    final board = boardData.map((cell) => cell as String?).toList();
    
    // Determine if it's current user's turn
    final currentPlayerId = data['currentPlayerId'] as String?;
    final isMyTurn = currentPlayerId == _currentUserId;
    
    emit(state.copyWith(
      isLoading: false,
      isGameActive: data['isActive'] as bool? ?? false,
      gameType: data['type'] as String?,
      currentPlayerId: currentPlayerId,
      winnerId: data['winnerId'] as String?,
      isDraw: data['isDraw'] as bool? ?? false,
      board: board,
      players: players,
      gameData: data,
      moveCount: data['moveCount'] as int? ?? 0,
      startTime: data['startTime'] != null
          ? DateTime.parse(data['startTime'] as String)
          : null,
      endTime: data['endTime'] != null
          ? DateTime.parse(data['endTime'] as String)
          : null,
      isMyTurn: isMyTurn,
      settings: data['settings'] as Map<String, dynamic>?,
    ));
  }

  Future<void> _onEndGame(
    EndGame event,
    Emitter<GameState> emit,
  ) async {
    if (_roomId == null) return;
    
    try {
      final gameData = {
        'isActive': false,
        'winnerId': event.winnerId,
        'endTime': DateTime.now().toIso8601String(),
        'endReason': event.reason,
      };
      
      await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(_roomId)
          .update({'game': gameData});
    } catch (e) {
      emit(state.copyWith(error: 'Failed to end game: $e'));
    }
  }

  void _onResetGame(
    ResetGame event,
    Emitter<GameState> emit,
  ) {
    emit(const GameState(
      isInitialized: true,
    ));
  }

  Future<void> _onPlayerJoined(
    PlayerJoined event,
    Emitter<GameState> emit,
  ) async {
    if (_roomId == null) return;
    
    try {
      // Assign symbol based on order
      final symbol = state.players.isEmpty ? 'X' : 'O';
      
      final newPlayer = GamePlayer(
        id: event.playerId,
        name: event.playerName,
        symbol: symbol,
      );
      
      final updatedPlayers = [...state.players, newPlayer];
      
      await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(_roomId)
          .update({
        'game.players': updatedPlayers.map((p) => p.toJson()).toList(),
      });
    } catch (e) {
      emit(state.copyWith(error: 'Failed to join game: $e'));
    }
  }

  Future<void> _onPlayerLeft(
    PlayerLeft event,
    Emitter<GameState> emit,
  ) async {
    if (_roomId == null) return;
    
    try {
      final updatedPlayers = state.players
          .where((p) => p.id != event.playerId)
          .toList();
      
      await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(_roomId)
          .update({
        'game.players': updatedPlayers.map((p) => p.toJson()).toList(),
      });
      
      // End game if only one player left
      if (updatedPlayers.length < 2 && state.isGameActive) {
        add(const EndGame(reason: 'player_left'));
      }
    } catch (e) {
      emit(state.copyWith(error: 'Failed to process player leave: $e'));
    }
  }

  void _onToggleGameMode(
    ToggleGameMode event,
    Emitter<GameState> emit,
  ) {
    emit(state.copyWith(isGameActive: event.isGameActive));
  }

  void _onGameError(
    GameErrorOccurred event,
    Emitter<GameState> emit,
  ) {
    emit(state.copyWith(error: event.error));
  }

  // ==========================================================================
  // Connection State Handling (Reconnect Recovery)
  // ==========================================================================
  
  void _onConnectionStateChanged(MultiplayerConnectionState connectionState) {
    _dbg('Connection state changed: $connectionState');
    
    switch (connectionState) {
      case MultiplayerConnectionState.waiting:
        _isReconnecting = true;
        break;
      case MultiplayerConnectionState.active:
        if (_isReconnecting) {
          _isReconnecting = false;
          _processPendingOperations();
        }
        break;
      case MultiplayerConnectionState.done:
        _isReconnecting = true;
        break;
    }
  }
  
  Future<void> _processPendingOperations() async {
    if (_pendingOperations.isEmpty) return;
    
    _dbg('Processing ${_pendingOperations.length} pending operations');
    
    // Sort by timestamp to maintain order
    _pendingOperations.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    final operationsToProcess = List<_PendingGameOperation>.from(_pendingOperations);
    _pendingOperations.clear();
    
    for (final op in operationsToProcess) {
      try {
        switch (op.type) {
          case _GameOperationType.move:
            await _multiplayerService.executeMove(
              roomId: op.roomId,
              position: op.data['position'],
              playerId: op.data['playerId'],
              extraData: op.data['extraData'],
            );
            break;
        }
      } catch (e) {
        _dbg('Failed to process pending operation: $e');
      }
    }
  }

  // ==========================================================================
  // Helpers
  // ==========================================================================

  /// Subscribe to game state via MultiplayerService
  /// MultiplayerService owns the stream - we just receive updates
  Future<void> _subscribeToGameState(String roomId) async {
    await _gameStateSubscription?.cancel();
    
    _gameStateSubscription = _multiplayerService
        .joinRoom(roomId)
        .listen(
      (gameData) {
        if (gameData != null) {
          add(GameStateUpdated(gameData));
        }
      },
      onError: (error) {
        _dbg('Game state stream error: $error');
        add(GameErrorOccurred('Connection error: $error'));
      },
    );
  }

  List<int>? _checkWinner(List<String?> board) {
    if (board.length != 9) return null;
    
    const winningCombinations = [
      [0, 1, 2], [3, 4, 5], [6, 7, 8],
      [0, 3, 6], [1, 4, 7], [2, 5, 8],
      [0, 4, 8], [2, 4, 6],
    ];

    for (final combo in winningCombinations) {
      final a = board[combo[0]];
      final b = board[combo[1]];
      final c = board[combo[2]];
      
      if (a != null && a == b && a == c) {
        return combo;
      }
    }
    return null;
  }

  void _dbg(String message) {
    assert(() {
      debugPrint('[GameBloc] $message');
      return true;
    }());
  }

  @override
  Future<void> close() async {
    // Cancel our subscriptions
    await _gameStateSubscription?.cancel();
    await _connectionSubscription?.cancel();
    
    // Leave room via MultiplayerService (proper disposal ownership)
    await _multiplayerService.leaveRoom();
    
    return super.close();
  }
}

// ============================================================================
// Internal Types for Pending Operations
// ============================================================================

enum _GameOperationType { move }

class _PendingGameOperation {
  final _GameOperationType type;
  final String roomId;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  _PendingGameOperation({
    required this.type,
    required this.roomId,
    required this.data,
  }) : timestamp = DateTime.now();
}

// ============================================================================
// Event Bus Event Classes
// ============================================================================

class GameStartedEvent {
  final String gameType;
  final String roomId;
  final String traceId;

  const GameStartedEvent({
    required this.gameType,
    required this.roomId,
    required this.traceId,
  });
}

class GameEndedEvent {
  final String? winnerId;
  final bool isDraw;
  final String roomId;
  final String traceId;

  const GameEndedEvent({
    this.winnerId,
    this.isDraw = false,
    required this.roomId,
    required this.traceId,
  });
}

class MoveMadeEvent {
  final int position;
  final String playerId;
  final String roomId;
  final String traceId;

  const MoveMadeEvent({
    required this.position,
    required this.playerId,
    required this.roomId,
    required this.traceId,
  });
}

class PlayerJoinedEvent {
  final String playerId;
  final String playerName;
  final String roomId;
  final String traceId;

  const PlayerJoinedEvent({
    required this.playerId,
    required this.playerName,
    required this.roomId,
    required this.traceId,
  });
}

class GameStateChangedEvent {
  final bool isActive;
  final String traceId;

  const GameStateChangedEvent({
    required this.isActive,
    required this.traceId,
  });
}

class GameErrorEvent {
  final String error;
  final String? operation;
  final String traceId;

  const GameErrorEvent({
    required this.error,
    this.operation,
    required this.traceId,
  });
}

