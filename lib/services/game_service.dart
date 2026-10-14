import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../utils/encryption.dart';
import 'offline_queue_manager.dart';

/// GameService provides game logic operations.
///
/// ARCHITECTURE NOTE: Stream ownership has been moved to MultiplayerService.
/// For stream subscriptions, use MultiplayerService instead of GameService.gameStream().
/// This service is now focused on:
/// - Game logic (win detection, board updates)
/// - Firestore transaction operations
/// - Move validation
class GameService {
  static final _firestore = FirebaseFirestore.instance;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[GameService] $message');
      return true;
    }());
  }

  static const _winPatterns = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ];

  // ── DEPRECATED: Stream caching moved to MultiplayerService ──────────────────
  // 
  // IMPORTANT: Use MultiplayerService for stream subscriptions instead:
  //   MultiplayerService().joinRoom(roomId)
  // 
  // This stream cache is kept for backward compatibility but should not
  // be used for new code. It delegates to MultiplayerService when possible.
  static final Map<String, Stream<DocumentSnapshot>> _streamCache = {};
  static final Set<String> _roomsOwnedByMultiplayer = {};

  /// DEPRECATED: Use MultiplayerService.joinRoom() instead.
  /// 
  /// Returns a game state stream. For proper lifecycle management,
  /// subscribe via MultiplayerService which handles dispose ownership.
  @Deprecated('Use MultiplayerService.joinRoom() for proper stream lifecycle management')
  static Stream<DocumentSnapshot> gameStream(String roomId) {
    _dbg('DEPRECATED: gameStream called for $roomId - use MultiplayerService instead');
    return _streamCache.putIfAbsent(
      roomId,
      () => _firestore.collection('chat_rooms').doc(roomId).snapshots(),
    );
  }

  /// Mark a room as being managed by MultiplayerService.
  /// When a room is owned by MultiplayerService, GameService will not
  /// dispose its stream to prevent conflicts.
  static void markRoomOwnedByMultiplayer(String roomId) {
    _roomsOwnedByMultiplayer.add(roomId);
    _dbg('Room $roomId now owned by MultiplayerService');
  }

  /// Check if a room stream is owned by MultiplayerService.
  static bool isRoomOwnedByMultiplayer(String roomId) {
    return _roomsOwnedByMultiplayer.contains(roomId);
  }

  static bool _isDisposed = false;

  static bool isStreamDisposed(String roomId) => _isDisposed;

  static void markDisposed() => _isDisposed = true;

  static void resetDisposed() => _isDisposed = false;

  /// Dispose stream for a room.
  /// If the room is owned by MultiplayerService, this is a no-op.
  static void disposeStream(String roomId) {
    if (roomId.isEmpty) return;
    if (_roomsOwnedByMultiplayer.contains(roomId)) {
      _dbg('Stream $roomId owned by MultiplayerService - not disposing from GameService');
      return;
    }
    _streamCache.remove(roomId);
  }

  /// Safe dispose with ownership check.
  static void disposeStreamSafe(String roomId, String expectedOwner) {
    if (roomId.isEmpty) return;
    if (expectedOwner == 'MultiplayerService') {
      _roomsOwnedByMultiplayer.remove(roomId);
      return;
    }
    if (_roomsOwnedByMultiplayer.contains(roomId)) {
      return; // Don't dispose if owned by MultiplayerService
    }
    final stream = _streamCache[roomId];
    if (stream == null) return;
    _streamCache.remove(roomId);
  }

  /// Clear all streams not owned by MultiplayerService.
  static void clearAllStreams() {
    final owned = Set<String>.from(_roomsOwnedByMultiplayer);
    _streamCache.removeWhere((roomId, _) => !owned.contains(roomId));
    _dbg('Cleared streams except MultiplayerService-owned: $owned');
  }
  
  /// Clear all streams including MultiplayerService-owned (call on logout).
  static void clearAllStreamsForce() {
    _streamCache.clear();
    _roomsOwnedByMultiplayer.clear();
    _dbg('Force cleared all streams');
  }

  // ── Shared ───────────────────────────────────────────────────────────────────

  static Future<void> resetGame({required String roomId}) async {
    _dbg('resetGame: room=$roomId');
    await _firestore.collection('chat_rooms').doc(roomId).update({'game': null});
  }

  // ── Tic Tac Toe ─────────────────────────────────────────────────────────────

  static Future<void> startGame({
    required String roomId,
    required String currentUserId,
    required String opponentId,
    String type = 'tictactoe',  // Default to tictactoe for backward compatibility
  }) async {
    _dbg('startGame: room=$roomId, type=$type');
    
    final ref = _firestore.collection('chat_rooms').doc(roomId);
    
    // Check previous game to alternate who goes first
    final prevDoc = await ref.get();
    final prevGame = prevDoc.data()?['game'] as Map?;
    final prevWinner = prevGame?['winner'] as String?;
    
    String firstTurn;
    if (prevWinner != null) {
      // Loser gets to go first next game
      final players = List<String>.from(prevGame?['players'] ?? []);
      firstTurn = players.firstWhere((p) => p != prevWinner, orElse: () => currentUserId);
      _dbg('startGame: previous winner was $prevWinner, loser $firstTurn goes first');
    } else {
      // No previous winner - alternate normally (use current user)
      firstTurn = currentUserId;
      _dbg('startGame: no previous winner, $firstTurn goes first');
    }
    
    // Initialize board based on game type
    List<dynamic> initialBoard;
    switch (type) {
      case 'tictactoe':
        initialBoard = List.filled(9, '');  // 3x3 grid
        break;
      case 'connectfour':
        initialBoard = List.filled(42, '');  // 6 rows x 7 cols = 42 cells
        break;
      case 'numberguess':
        initialBoard = [];  // Number guess doesn't use a board
        break;
      default:
        initialBoard = List.filled(9, '');
    }
    
    await ref.set({
      'game': {
        'type': type,
        'board': initialBoard,
        'currentTurn': firstTurn,
        'players': [currentUserId, opponentId],
        'status': 'playing',
        'winner': null,
        'winningCells': [],  // Clear winning cells from previous game
      },
    }, SetOptions(merge: true));
  }

  /// Places a move using a Firestore transaction.
  ///
  /// Transaction ensures:
  /// 1. Game is still "playing" (not finished/draw)
  /// 2. It's this player's turn (prevents double-move race)
  /// 3. Cell is empty (prevents overwriting)
  /// 4. All state changes (board + turn + status) happen atomically
  ///
  /// CRITICAL FIX: Previously validated locally from a potentially stale
  /// `gameData` snapshot. Two players tapping simultaneously could both
  /// read "my turn" before either writes, causing one move to be silently
  /// dropped. With transactions, only one player's write succeeds and the
  /// other gets a fresh read.
  static Future<void> makeMove({
    required String roomId,
    required int index,
    required String currentUserId,
  }) async {
    // Stale move prevention
    final moveId = '${roomId}_${currentUserId}_$index';
    final canProceed = await GameMoveValidator.shouldAllowMove(roomId, moveId);
    if (!canProceed) {
      _dbg('makeMove: rejected stale move');
      return;
    }

    _dbg('makeMove: room=$roomId, index=$index, uid=$currentUserId');

    final ref = _firestore.collection('chat_rooms').doc(roomId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;

      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData['game'] as Map<String, dynamic>?;

      if (gameData == null) {
        _dbg('makeMove: no game data');
        return;
      }

      if (gameData['status'] != 'playing') {
        _dbg('makeMove: rejected — game not playing');
        return;
      }

      if (gameData['currentTurn'] != currentUserId) {
        _dbg('makeMove: rejected — not your turn');
        return;
      }

      final board = List<String>.from(gameData['board'] as List);
      if (index < 0 || index >= board.length || board[index].isNotEmpty) {
        _dbg('makeMove: rejected — cell invalid or occupied');
        return;
      }

      final players = List<String>.from(gameData['players'] as List);
      final symbol = players[0] == currentUserId ? 'X' : 'O';
      final opponentId = players.firstWhere((id) => id != currentUserId);

      board[index] = symbol;

      final winnerId = _checkWinner(board, players);
      final isDraw = winnerId == null && board.every((cell) => cell.isNotEmpty);

      final updates = <String, dynamic>{
        'game.board': board,
        'game.currentTurn': opponentId,
      };

      if (winnerId != null) {
        updates['game.status'] = 'finished';
        updates['game.winner'] = winnerId;
        final winPositions = _getWinningPositions(board);
        updates['game.winningCells'] = winPositions ?? [];
        _dbg('makeMove: winner=$winnerId, winningCells=$winPositions');
      } else if (isDraw) {
        updates['game.status'] = 'draw';
        _dbg('makeMove: draw');
      }

      tx.update(ref, updates);
    });

    _dbg('makeMove: committed');
  }

  static String? _checkWinner(List<String> board, List<String> players) {
    for (final pattern in _winPatterns) {
      final a = board[pattern[0]];
      final b = board[pattern[1]];
      final c = board[pattern[2]];
      if (a.isNotEmpty && a == b && b == c) {
        return a == 'X' ? players[0] : players[1];
      }
    }
    return null;
  }

  static List<int>? _getWinningPositions(List<String> board) {
    for (final pattern in _winPatterns) {
      final a = board[pattern[0]];
      if (a.isNotEmpty && a == board[pattern[1]] && a == board[pattern[2]]) {
        return pattern;
      }
    }
    return null;
  }

  // ── Connect Four ─────────────────────────────────────────────────────────────

  static Future<void> startConnectFourGame({
    required String roomId,
    required String currentUserId,
    required String opponentId,
  }) async {
    await _firestore.collection('chat_rooms').doc(roomId).set({
      'game': {
        'type': 'connectfour',
        'player1Id': currentUserId,
        'player2Id': opponentId,
        'board': _emptyConnectFourBoard(),
        'currentPlayer': currentUserId,
        'status': 'playing',
        'winner': null,
        'winningCells': [],
      },
    }, SetOptions(merge: true));
  }

  static List<String> _emptyConnectFourBoard() => List.filled(42, '');

  /// Places a Connect Four move using a Firestore transaction.
  /// Same atomic guarantees as makeMove() — prevents simultaneous drops
  /// and stale-snapshot rejection.
  static Future<bool> makeConnectFourMove({
    required String roomId,
    required int column,
    required String currentUserId,
  }) async {
    _dbg('makeConnectFourMove: room=$roomId, col=$column, uid=$currentUserId');

    if (column < 0 || column > 6) {
      _dbg('makeConnectFourMove: invalid column');
      return false;
    }

    final ref = _firestore.collection('chat_rooms').doc(roomId);
    bool success = false;

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;

      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData['game'] as Map<String, dynamic>?;

      if (gameData == null) return;

      if (gameData['status'] != 'playing') {
        _dbg('makeConnectFourMove: rejected — not playing');
        return;
      }

      if (gameData['currentPlayer'] != currentUserId) {
        _dbg('makeConnectFourMove: rejected — not your turn');
        return;
      }

      final board = List<String>.from(gameData['board'] as List);

      // CORRECTED: Search from BOTTOM (row 0) upward to TOP (row 5)
      // Row 0 = bottom of board (lowest position), row 5 = top of board
      int? dropRow;
      for (int row = 0; row < 6; row++) {
        final idx = row * 7 + column;
        if (board[idx].isEmpty) {
          dropRow = row;
          _dbg('makeConnectFourMove: selected row=$row (BOTTOM-FIRST)');
          break;
        }
      }

      if (dropRow == null) {
        _dbg('makeConnectFourMove: column full');
        return;
      }

      final symbol = currentUserId == gameData['player1Id'] ? 'X' : 'O';
      final index = dropRow * 7 + column;
      board[index] = symbol;

      final winResult = _checkConnectFourWinner(board, column, dropRow, symbol);
      final opponentId = currentUserId == gameData['player1Id']
          ? gameData['player2Id']
          : gameData['player1Id'];

      final isDraw = winResult == null && board.every((c) => c.isNotEmpty);

      final updates = <String, dynamic>{
        'game.board': board,
        'game.currentPlayer': opponentId,
        'game.lastMove': {
          'column': column,
          'row': dropRow,
          'playerId': currentUserId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      };

      if (winResult != null) {
        updates['game.status'] = 'finished';
        updates['game.winner'] = currentUserId;
        updates['game.winningCells'] = winResult;
        _dbg('makeConnectFourMove: win cells=$winResult');
      } else if (isDraw) {
        updates['game.status'] = 'draw';
        _dbg('makeConnectFourMove: draw');
      }

      tx.update(ref, updates);
      success = true;
    });

    _dbg('makeConnectFourMove: committed=$success');
    return success;
  }

  static List<int>? _checkConnectFourWinner(
    List<String> board,
    int lastCol,
    int lastRow,
    String symbol,
  ) {
    final directions = [
      [1, 0], [0, 1], [1, 1], [1, -1],
    ];

    for (final dir in directions) {
      final cells = <int>[lastRow * 7 + lastCol];
      int count = 1;

      for (int i = 1; i < 4; i++) {
        final c = lastCol + i * dir[0];
        final r = lastRow + i * dir[1];
        if (c >= 0 && c < 7 && r >= 0 && r < 6) {
          final idx = r * 7 + c;
          if (board[idx] == symbol) {
            cells.add(idx);
            count++;
          } else {
            break;
          }
        }
      }

      for (int i = 1; i < 4; i++) {
        final c = lastCol - i * dir[0];
        final r = lastRow - i * dir[1];
        if (c >= 0 && c < 7 && r >= 0 && r < 6) {
          final idx = r * 7 + c;
          if (board[idx] == symbol) {
            cells.add(idx);
            count++;
          } else {
            break;
          }
        }
      }

      if (count >= 4) return cells;
    }

    return null;
  }

  static Future<void> resetConnectFourGame({
    required String roomId,
    required String currentUserId,
  }) async {
    _dbg('resetConnectFourGame: room=$roomId, uid=$currentUserId');
    final ref = _firestore.collection('chat_rooms').doc(roomId);
    final stopwatch = Stopwatch()..start();
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData['game'] as Map<String, dynamic>?;
      if (gameData == null) return;
      // Alternate who starts: winner of previous game goes second
      String nextPlayer;
      if (gameData['winner'] != null) {
        // Previous winner goes second, other player goes first
        nextPlayer = gameData['winner'] == gameData['player1Id'] 
            ? gameData['player2Id'] 
            : gameData['player1Id'];
        _dbg('resetConnectFourGame: previous winner was ${gameData["winner"]}, $nextPlayer goes first');
      } else {
        // Draw or no winner - alternate: player2 goes first
        nextPlayer = gameData['player2Id'];
        _dbg('resetConnectFourGame: draw or no winner, player2 $nextPlayer goes first');
      }
      
      tx.update(ref, {
        'game.board': _emptyConnectFourBoard(),
        'game.status': 'playing',
        'game.winner': null,
        'game.winningCells': [],
        'game.currentPlayer': nextPlayer,
      });
    });
    stopwatch.stop();
    _dbg('resetConnectFourGame: committed, latency=${stopwatch.elapsedMilliseconds}ms');
  }

  // ── Number Guess ─────────────────────────────────────────────────────────────

  static Future<void> startNumberGuessGame({
    required String roomId,
    required String currentUserId,
    required String opponentId,
    required int number,
    required int min,
    required int max,
  }) async {
    _dbg('[GAME] startNumberGuessGame: room=$roomId, uid=$currentUserId, opponent=$opponentId');
    final encrypted = await EncryptionHelper.encryptMessage(number.toString());
    final ref = _firestore.collection('chat_rooms').doc(roomId);

    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(ref);
      final data = doc.data();
      final gameData = data?['game'] as Map<String, dynamic>?;

      if (gameData != null) {
        final submitted = List<String>.from(gameData['submitted'] ?? []);
        final numberSetter = gameData['numberSetter'] as String?;
        final guesser = gameData['guesser'] as String?;
        
        _dbg('[GAME] existing game found: setter=$numberSetter, guesser=$guesser, submitted=$submitted');

        // ✅ FIX: Idempotent - check all "already in game" conditions first
        
        // Case 1: User already fully submitted their number
        if (submitted.contains(currentUserId)) {
          _dbg('[GAME] user $currentUserId already submitted - resuming session');
          return; // Success: already in game
        }
        
        // Case 2: User is the numberSetter but hasn't submitted yet (should not happen normally)
        if (numberSetter == currentUserId) {
          _dbg('[GAME] user $currentUserId is numberSetter but not in submitted list - adding');
          // Continue to add them below
        }
        
        // Case 3: User is already defined as guesser but hasn't submitted yet
        // This happens when the creator set opponent as guesser during game creation
        // We need to actually submit the number now
        if (guesser == currentUserId && !submitted.contains(currentUserId)) {
          _dbg('[GAME] predefined guesser $currentUserId submitting number');
          _dbg('[GAME] submitted was: $submitted, adding $currentUserId');
          
          // Add to submitted list - now both players have submitted
          final newSubmitted = [...submitted, currentUserId];
          
          transaction.update(ref, {
            'game.number_$currentUserId': encrypted['text'],
            'game.numberKey_$currentUserId': encrypted['key'],
            'game.numberIv_$currentUserId': encrypted['iv'],
            'game.min_$currentUserId': min,
            'game.max_$currentUserId': max,
            'game.lastGuess_$currentUserId': null,
            'game.hint_$currentUserId': null,
            'game.guessCount_$currentUserId': 0,
            'game.submitted': newSubmitted,
            'game.status': 'playing',
            'game.guessTurn': numberSetter,
          });
          _dbg('[GAME] guesser submitted number, status=playing, turn=$numberSetter');
          return;
        }
        
        // Case 4: Game needs a guesser, user becomes second player
        // This handles the case where guesser was NOT predefined (fallback for legacy/edge cases)
        if (guesser == null && numberSetter == opponentId) {
          _dbg('[GAME] adding $currentUserId as guesser');
          transaction.update(ref, {
            'game.guesser': currentUserId,
            'game.number_$currentUserId': encrypted['text'],
            'game.numberKey_$currentUserId': encrypted['key'],
            'game.numberIv_$currentUserId': encrypted['iv'],
            'game.min_$currentUserId': min,
            'game.max_$currentUserId': max,
            'game.lastGuess_$currentUserId': null,
            'game.hint_$currentUserId': null,
            'game.guessCount_$currentUserId': 0,
            'game.submitted': FieldValue.arrayUnion([currentUserId]),
            'game.status': 'playing',
          });
          _dbg('[GAME] added as guesser successfully');
          return;
        }

        // Case 4b: User is creating new game but gameData exists from previous game
        // Reset the game and create fresh
        if (numberSetter != null && numberSetter != currentUserId && numberSetter != opponentId) {
          _dbg('[GAME] existing game from different players, resetting and creating new');
          // Fall through to create new game below
        }
        
        // Case 5: Game is full, check if user is one of the players
        if (numberSetter != null && guesser != null) {
          if (currentUserId == numberSetter || currentUserId == guesser) {
            _dbg('[GAME] game full but user $currentUserId is a player - resuming');
            return; // Success: already in game
          }
          _dbg('[GAME] ERROR: game full and user not a participant');
          throw Exception('Game already has both players');
        }
        
        // Case 6: User wants to create new game, clear existing incomplete game
        // This handles: numberSetter is null, or different user, or incomplete game
        _dbg('[GAME] resetting game and creating new with $currentUserId as numberSetter');
        
        // Clear the old game completely and create fresh
        transaction.update(ref, {
          'game': {
            'type': 'numberguess',
            'numberSetter': currentUserId,
            'guesser': opponentId,
            'number_$currentUserId': encrypted['text'],
            'numberKey_$currentUserId': encrypted['key'],
            'numberIv_$currentUserId': encrypted['iv'],
            'min_$currentUserId': min,
            'max_$currentUserId': max,
            'min': min,
            'max': max,
            'lastGuess_$currentUserId': null,
            'hint_$currentUserId': null,
            'guessCount_$currentUserId': 0,
            'submitted': [currentUserId],
            'status': 'waiting',
            'guessTurn': null,
            'winner': null,
          },
        });
        _dbg('[GAME] new game created successfully (reset from old state)');
        return;
      }

      // Create new game - current user is the creator (numberSetter)
      _dbg('[GAME] creating new game with $currentUserId as numberSetter');
      transaction.set(ref, {
        'game': {
          'type': 'numberguess',
          'numberSetter': currentUserId,
          'guesser': opponentId,
          'number_$currentUserId': encrypted['text'],
          'numberKey_$currentUserId': encrypted['key'],
          'numberIv_$currentUserId': encrypted['iv'],
          'min_$currentUserId': min,
          'max_$currentUserId': max,
          'min': min,
          'max': max,
          'lastGuess_$currentUserId': null,
          'hint_$currentUserId': null,
          'guessCount_$currentUserId': 0,
          'submitted': [currentUserId],
          'status': 'waiting',
          'guessTurn': null,
          'winner': null,
        },
      }, SetOptions(merge: true));
      _dbg('[GAME] new game created successfully');
    });
  }

  static Future<void> joinNumberGuessGame({
    required String roomId,
    required String currentUserId,
    required int number,
    required int min,
    required int max,
  }) async {
    _dbg('[GAME] joinNumberGuessGame: room=$roomId, uid=$currentUserId');
    final encrypted = await EncryptionHelper.encryptMessage(number.toString());
    final ref = _firestore.collection('chat_rooms').doc(roomId);

    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(ref);
      final data = doc.data();
      if (data == null) throw Exception('Chat room does not exist');

      final gameData = data['game'] as Map<String, dynamic>?;
      if (gameData == null) throw Exception('No game in progress');

      final numberSetter = gameData['numberSetter'] as String?;
      final guesser = gameData['guesser'] as String?;
      
      _dbg('[GAME] join: setter=$numberSetter, guesser=$guesser');
      
      if (numberSetter == null || guesser == null) {
        throw Exception('Invalid game setup');
      }

      // Check if user is already a participant
      if (currentUserId != numberSetter && currentUserId != guesser) {
        _dbg('[GAME] join ERROR: user not a participant');
        throw Exception('Not a participant');
      }

      final submitted = List<String>.from(gameData['submitted'] ?? []);
      
      // ✅ FIX: Idempotent - already submitted = success
      if (submitted.contains(currentUserId)) {
        _dbg('[GAME] join: user $currentUserId already submitted - resuming');
        return; // Success: already in game
      }

      // Add user to submitted list
      submitted.add(currentUserId);
      
      _dbg('[GAME] join: adding $currentUserId with number');

      transaction.update(ref, {
        'game.number_$currentUserId': encrypted['text'],
        'game.numberKey_$currentUserId': encrypted['key'],
        'game.numberIv_$currentUserId': encrypted['iv'],
        'game.min_$currentUserId': min,
        'game.max_$currentUserId': max,
        'game.lastGuess_$currentUserId': null,
        'game.hint_$currentUserId': null,
        'game.guessCount_$currentUserId': 0,
        'game.submitted': submitted,
        'game.status': 'playing',
        'game.guessTurn': numberSetter,
      });
      
      _dbg('[GAME] join: user $currentUserId added successfully');
    }).catchError((e) {
      assert(() {
        debugPrint('[GameService] joinNumberGuessGame error: $e');
        return true;
      }());
      throw e;
    });
  }

  static Future<void> makeNumberGuess({
    required String roomId,
    required int guess,
    required String currentUserId,
  }) async {
    _dbg('makeNumberGuess: room=$roomId, guess=$guess, uid=$currentUserId');
    final stopwatch = Stopwatch()..start();

    final ref = _firestore.collection('chat_rooms').doc(roomId);

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 1: Read current state (outside transaction)
    // ─────────────────────────────────────────────────────────────────────────
    final snap = await ref.get();
    if (!snap.exists) {
      _dbg('makeNumberGuess: room not found');
      return;
    }

    final roomData = snap.data() as Map<String, dynamic>;
    final gameData = roomData['game'] as Map<String, dynamic>?;
    if (gameData == null) {
      _dbg('makeNumberGuess: no game data');
      return;
    }
    if (gameData['status'] != 'playing') {
      _dbg('makeNumberGuess: rejected — not playing');
      return;
    }
    if (gameData['guessTurn'] != currentUserId) {
      _dbg('makeNumberGuess: rejected — not your turn');
      return;
    }

    final numberSetter = gameData['numberSetter'] as String;
    final opponentUid = currentUserId == numberSetter
        ? (gameData['guesser'] as String)
        : numberSetter;

    final min = (gameData['min_$opponentUid'] as int?) ?? (gameData['min'] as int? ?? 1);
    final max = (gameData['max_$opponentUid'] as int?) ?? (gameData['max'] as int? ?? 100);

    if (guess < min || guess > max) {
      throw RangeError.range(guess, min, max,
        'guess', 'Guess must be between $min and $max');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 2: Decrypt secret (OUTSIDE transaction - no async in transaction!)
    // ─────────────────────────────────────────────────────────────────────────
    final encryptedSecret = gameData['number_$opponentUid'] as String?;
    final key = gameData['numberKey_$opponentUid'] as String?;
    final iv = gameData['numberIv_$opponentUid'] as String?;

    if (encryptedSecret == null || key == null || iv == null) {
      _dbg('makeNumberGuess: missing encryption data');
      return;
    }

    String decryptedSecret;
    try {
      decryptedSecret = await EncryptionHelper.decryptMessage(encryptedSecret, key, iv);
    } catch (e) {
      _dbg('makeNumberGuess: decrypt failed ${e.runtimeType}');
      return;
    }

    final secret = int.tryParse(decryptedSecret);
    if (secret == null) {
      _dbg('makeNumberGuess: invalid secret');
      return;
    }

    // Determine hint (deterministic, no side effects)
    String hint;
    bool correct = false;

    if (guess == secret) {
      hint = '🎉 Correct!';
      correct = true;
    } else if (guess < secret) {
      hint = '⬆️ Higher! (Your guess: $guess)';
    } else {
      hint = '⬇️ Lower! (Your guess: $guess)';
    }

    final guessCount = (gameData['guessCount_$currentUserId'] as int? ?? 0) + 1;

    _dbg('makeNumberGuess: determined hint=$hint, correct=$correct');

    // ─────────────────────────────────────────────────────────────────────────
    // PHASE 3: Atomic write (inside transaction - NO async/await!)
    // ─────────────────────────────────────────────────────────────────────────
    await _firestore.runTransaction((tx) async {
      final freshSnap = await tx.get(ref);
      if (!freshSnap.exists) {
        _dbg('makeNumberGuess: room disappeared during transaction');
        return;
      }

      final freshRoomData = freshSnap.data() as Map<String, dynamic>;
      final freshGameData = freshRoomData['game'] as Map<String, dynamic>?;
      if (freshGameData == null) {
        _dbg('makeNumberGuess: game disappeared during transaction');
        return;
      }
      
      // Verify turn hasn't changed
      if (freshGameData['guessTurn'] != currentUserId) {
        _dbg('makeNumberGuess: turn changed during decrypt');
        return;
      }

      final updates = <String, dynamic>{
        'game.lastGuess_$currentUserId': guess,
        'game.hint_$currentUserId': hint,
        'game.guessCount_$currentUserId': guessCount,
        'game.guessTurn': opponentUid,
        'game.guessHistory_$currentUserId': FieldValue.arrayUnion([
          {'guess': guess, 'hint': hint, 'at': DateTime.now().millisecondsSinceEpoch}
        ]),
      };

      if (correct) {
        updates['game.status'] = 'finished';
        updates['game.winner'] = currentUserId;
      }

      tx.update(ref, updates);
      _dbg('makeNumberGuess: transaction committed');
    });

    stopwatch.stop();
    _dbg('makeNumberGuess: total latency=${stopwatch.elapsedMilliseconds}ms');
  }

  static Future<void> resetNumberGuessGame({required String roomId}) async {
    _dbg('resetNumberGuessGame: room=$roomId');
    await _firestore.collection('chat_rooms').doc(roomId).update({'game': null});
  }

  /// Forfeit the game - opponent wins by timeout
  static Future<void> forfeitGame({
    required String roomId,
    required String currentUserId,
  }) async {
    _dbg('forfeitGame: room=$roomId, uid=$currentUserId');
    final ref = _firestore.collection('chat_rooms').doc(roomId);
    
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      
      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData['game'] as Map<String, dynamic>?;
      if (gameData == null) return;
      
      // Determine opponent as winner
      final players = List<String>.from(gameData['players'] ?? []);
      final opponentId = players.firstWhere((p) => p != currentUserId, orElse: () => '');
      
      if (opponentId.isEmpty) {
        _dbg('forfeitGame: could not find opponent');
        return;
      }
      
      tx.update(ref, {
        'game.status': 'finished',
        'game.winner': opponentId,
        'game.forfeitedBy': currentUserId,
      });
      
      _dbg('forfeitGame: opponent $opponentId wins by forfeit');
    });
  }
}
