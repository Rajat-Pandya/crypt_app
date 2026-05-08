import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../utils/encryption.dart';

class GameService {
  static final _firestore = FirebaseFirestore.instance;

  static void _dbg(String message) {
    debugPrint('[GameService] $message');
  }

  static const _winPatterns = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ];

  // ── Stream caching ───────────────────────────────────────────────────────────
  // CRITICAL FIX: Each roomId maps to exactly ONE stream instance.
  // Previously, gameStream() created a new stream on every call.
  // StreamBuilder in game screens passes `stream:` inline — each rebuild
  // called gameStream() again, creating duplicate listeners for the same room.
  // Now: same roomId always returns the same stream reference, so
  // StreamBuilder receives the same stream on every rebuild → no duplicates.
  static final Map<String, Stream<DocumentSnapshot>> _streamCache = {};

  static Stream<DocumentSnapshot> gameStream(String roomId) {
    return _streamCache.putIfAbsent(
      roomId,
      () => _firestore.collection("chat_rooms").doc(roomId).snapshots(),
    );
  }

  // Call this when leaving a game screen to prevent memory leaks.
  // The stream stays alive for the lifetime of the app — a small trade-off
  // vs duplicate listeners. Games are finite, but multiple listeners per game
  // cause desync and performance issues.
  static void disposeStream(String roomId) {
    _streamCache.remove(roomId);
  }

  static void clearAllStreams() => _streamCache.clear();

  // ── Shared ───────────────────────────────────────────────────────────────────

  static Future<void> resetGame({required String roomId}) async {
    _dbg('resetGame: room=$roomId');
    await _firestore.collection("chat_rooms").doc(roomId).update({"game": null});
  }

  // ── Tic Tac Toe ─────────────────────────────────────────────────────────────

  static Future<void> startGame({
    required String roomId,
    required String currentUserId,
    required String opponentId,
  }) async {
    _dbg('startGame: room=$roomId');
    await _firestore.collection("chat_rooms").doc(roomId).set({
      "game": {
        "type": "tictactoe",
        "board": List.filled(9, ""),
        "currentTurn": currentUserId,
        "players": [currentUserId, opponentId],
        "status": "playing",
        "winner": null,
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
    _dbg('makeMove: room=$roomId, index=$index, uid=$currentUserId');

    final ref = _firestore.collection("chat_rooms").doc(roomId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;

      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData["game"] as Map<String, dynamic>?;

      if (gameData == null) {
        _dbg('makeMove: no game data');
        return;
      }

      if (gameData["status"] != "playing") {
        _dbg('makeMove: rejected — game not playing');
        return;
      }

      if (gameData["currentTurn"] != currentUserId) {
        _dbg('makeMove: rejected — not your turn');
        return;
      }

      final board = List<String>.from(gameData["board"] as List);
      if (index < 0 || index >= board.length || board[index].isNotEmpty) {
        _dbg('makeMove: rejected — cell invalid or occupied');
        return;
      }

      final players = List<String>.from(gameData["players"] as List);
      final symbol = players[0] == currentUserId ? "X" : "O";
      final opponentId = players.firstWhere((id) => id != currentUserId);

      board[index] = symbol;

      final winnerId = _checkWinner(board, players);
      final isDraw = winnerId == null && board.every((cell) => cell.isNotEmpty);

      final updates = <String, dynamic>{
        "game.board": board,
        "game.currentTurn": opponentId,
      };

      if (winnerId != null) {
        updates["game.status"] = "finished";
        updates["game.winner"] = winnerId;
        _dbg('makeMove: winner=$winnerId');
      } else if (isDraw) {
        updates["game.status"] = "draw";
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
        return a == "X" ? players[0] : players[1];
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
    await _firestore.collection("chat_rooms").doc(roomId).set({
      "game": {
        "type": "connectfour",
        "player1Id": currentUserId,
        "player2Id": opponentId,
        "board": _emptyConnectFourBoard(),
        "currentPlayer": currentUserId,
        "status": "playing",
        "winner": null,
        "winningCells": [],
      },
    }, SetOptions(merge: true));
  }

  static List<String> _emptyConnectFourBoard() => List.filled(42, "");

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

    final ref = _firestore.collection("chat_rooms").doc(roomId);
    bool success = false;

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;

      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData["game"] as Map<String, dynamic>?;

      if (gameData == null) return;

      if (gameData["status"] != "playing") {
        _dbg('makeConnectFourMove: rejected — not playing');
        return;
      }

      if (gameData["currentPlayer"] != currentUserId) {
        _dbg('makeConnectFourMove: rejected — not your turn');
        return;
      }

      final board = List<String>.from(gameData["board"] as List);

      int? dropRow;
      for (int row = 5; row >= 0; row--) {
        final idx = row * 7 + column;
        if (board[idx].isEmpty) {
          dropRow = row;
          break;
        }
      }

      if (dropRow == null) {
        _dbg('makeConnectFourMove: column full');
        return;
      }

      final symbol = currentUserId == gameData["player1Id"] ? "X" : "O";
      final index = dropRow * 7 + column;
      board[index] = symbol;

      final winResult = _checkConnectFourWinner(board, column, dropRow, symbol);
      final opponentId = currentUserId == gameData["player1Id"]
          ? gameData["player2Id"]
          : gameData["player1Id"];

      final isDraw = winResult == null && board.every((c) => c.isNotEmpty);

      final updates = <String, dynamic>{
        "game.board": board,
        "game.currentPlayer": opponentId,
      };

      if (winResult != null) {
        updates["game.status"] = "finished";
        updates["game.winner"] = currentUserId;
        updates["game.winningCells"] = winResult;
        _dbg('makeConnectFourMove: win cells=$winResult');
      } else if (isDraw) {
        updates["game.status"] = "draw";
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
    final ref = _firestore.collection("chat_rooms").doc(roomId);
    final stopwatch = Stopwatch()..start();
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData["game"] as Map<String, dynamic>?;
      if (gameData == null) return;
      _dbg('resetConnectFourGame: preserving player1Id=${gameData["player1Id"]} as currentPlayer');
      tx.update(ref, {
        "game.board": _emptyConnectFourBoard(),
        "game.status": "playing",
        "game.winner": null,
        "game.winningCells": [],
        "game.currentPlayer": gameData["player1Id"],
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
    _dbg('startNumberGuessGame: room=$roomId');
    final encrypted = await EncryptionHelper.encryptMessage(number.toString());

    await _firestore.collection("chat_rooms").doc(roomId).set({
      "game": {
        "type": "numberguess",
        "numberSetter": currentUserId,
        "guesser": opponentId,
        "number_$currentUserId": encrypted["text"],
        "numberKey_$currentUserId": encrypted["key"],
        "numberIv_$currentUserId": encrypted["iv"],
        "min_$currentUserId": min,
        "max_$currentUserId": max,
        "min": min,
        "max": max,
        "lastGuess_$currentUserId": null,
        "hint_$currentUserId": null,
        "guessCount_$currentUserId": 0,
        "submitted": [currentUserId],
        "status": "waiting",
        "guessTurn": null,
        "winner": null,
      },
    }, SetOptions(merge: true));
  }

  static Future<void> joinNumberGuessGame({
    required String roomId,
    required String currentUserId,
    required int number,
    required int min,
    required int max,
  }) async {
    _dbg('joinNumberGuessGame: room=$roomId, uid=$currentUserId');
    final encrypted = await EncryptionHelper.encryptMessage(number.toString());
    final ref = _firestore.collection("chat_rooms").doc(roomId);

    await _firestore.runTransaction((transaction) async {
      final doc = await transaction.get(ref);
      final data = doc.data();
      if (data == null) throw Exception("Chat room does not exist");

      final gameData = data["game"] as Map<String, dynamic>?;
      if (gameData == null) throw Exception("No game in progress");

      final numberSetter = gameData["numberSetter"] as String?;
      final guesser = gameData["guesser"] as String?;
      if (numberSetter == null || guesser == null) {
        throw Exception("Invalid game setup");
      }

      if (currentUserId != numberSetter && currentUserId != guesser) {
        throw Exception("Not a participant");
      }

      final submitted = List<String>.from(gameData["submitted"] ?? []);
      if (submitted.contains(currentUserId)) return;

      submitted.add(currentUserId);

      transaction.update(ref, {
        "game.number_$currentUserId": encrypted["text"],
        "game.numberKey_$currentUserId": encrypted["key"],
        "game.numberIv_$currentUserId": encrypted["iv"],
        "game.min_$currentUserId": min,
        "game.max_$currentUserId": max,
        "game.lastGuess_$currentUserId": null,
        "game.hint_$currentUserId": null,
        "game.guessCount_$currentUserId": 0,
        "game.submitted": submitted,
        "game.status": "playing",
        "game.guessTurn": numberSetter,
      });
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

    final ref = _firestore.collection("chat_rooms").doc(roomId);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;

      final roomData = snap.data() as Map<String, dynamic>;
      final gameData = roomData["game"] as Map<String, dynamic>?;
      if (gameData == null) return;
      if (gameData["status"] != "playing") {
        _dbg('makeNumberGuess: rejected — not playing');
        return;
      }
      if (gameData["guessTurn"] != currentUserId) {
        _dbg('makeNumberGuess: rejected — not your turn');
        return;
      }

      final numberSetter = gameData["numberSetter"] as String;
      final opponentUid = currentUserId == numberSetter
          ? (gameData["guesser"] as String)
          : numberSetter;

      final min = (gameData["min_$opponentUid"] as int?) ?? (gameData["min"] as int? ?? 1);
      final max = (gameData["max_$opponentUid"] as int?) ?? (gameData["max"] as int? ?? 100);

      if (guess < min || guess > max) return;

      final encryptedSecret = gameData["number_$opponentUid"] as String?;
      final key = gameData["numberKey_$opponentUid"] as String?;
      final iv = gameData["numberIv_$opponentUid"] as String?;

      if (encryptedSecret == null || key == null || iv == null) return;

      String decryptedSecret;
      try {
        decryptedSecret = await EncryptionHelper.decryptMessage(encryptedSecret, key, iv);
      } catch (e) {
        _dbg('makeNumberGuess: decrypt failed ${e.runtimeType}');
        return;
      }

      final secret = int.tryParse(decryptedSecret);
      if (secret == null) return;

      String hint;
      bool correct = false;

      if (guess == secret) {
        hint = "🎉 Correct!";
        correct = true;
      } else if (guess < secret) {
        hint = "⬆️ Higher! (Your guess: $guess)";
      } else {
        hint = "⬇️ Lower! (Your guess: $guess)";
      }

      final guessCount = (gameData["guessCount_$currentUserId"] as int? ?? 0) + 1;

      final updates = <String, dynamic>{
        "game.lastGuess_$currentUserId": guess,
        "game.hint_$currentUserId": hint,
        "game.guessCount_$currentUserId": guessCount,
        "game.guessTurn": opponentUid,
      };

      if (correct) {
        updates["game.status"] = "finished";
        updates["game.winner"] = currentUserId;
      }

      tx.update(ref, updates);
    });

    stopwatch.stop();
    _dbg('makeNumberGuess: committed, latency=${stopwatch.elapsedMilliseconds}ms');
  }

  static Future<void> resetNumberGuessGame({required String roomId}) async {
    _dbg('resetNumberGuessGame: room=$roomId');
    await _firestore.collection("chat_rooms").doc(roomId).update({"game": null});
  }
}
