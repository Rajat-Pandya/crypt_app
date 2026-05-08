import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/game_state.dart';

import '../main.dart';
import '../services/game_service.dart';

class ConnectFourScreen extends StatefulWidget {
  final String roomId;
  final String opponentId;
  final String opponentName;

  const ConnectFourScreen({
    super.key,
    required this.roomId,
    required this.opponentId,
    required this.opponentName,
  });

  @override
  State<ConnectFourScreen> createState() => _ConnectFourScreenState();
}

class _ConnectFourScreenState extends State<ConnectFourScreen>
    with TickerProviderStateMixin {
  final currentUser = FirebaseAuth.instance.currentUser!;
  bool _initStarted = false;
  int _rebuildCount = 0;

  Stream<DocumentSnapshot>? _gameStream;

  late AnimationController _pulseController;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[ConnectFour] $message');
      return true;
    }());
  }

  @override
  void initState() {
    super.initState();
    GameState.isPlaying = true;
    debugPrint('[ConnectFour] initState: STARTING');
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _gameStream = GameService.gameStream(widget.roomId);
    _initGame();
    debugPrint('[ConnectFour] initState: COMPLETE');
  }

  Future<void> _initGame() async {
    if (_initStarted) {
      _dbg('_initGame: ALREADY STARTED — guard preventing duplicate init');
      return;
    }
    _initStarted = true;

    debugPrint('[ConnectFour] _initGame: fetching room=${widget.roomId}');
    final snap = await FirebaseFirestore.instance
        .collection("chat_rooms")
        .doc(widget.roomId)
        .get();

    final gameData = (snap.data()?["game"]) as Map<String, dynamic>?;
    debugPrint(
      '[ConnectFour] _initGame: gameData exists=${gameData != null}, type=${gameData?["type"]}',
    );

    if (gameData == null || gameData["type"] != "connectfour") {
      debugPrint('[ConnectFour] _initGame: creating new Connect Four game');
      await GameService.startConnectFourGame(
        roomId: widget.roomId,
        currentUserId: currentUser.uid,
        opponentId: widget.opponentId,
      );
      debugPrint('[ConnectFour] _initGame: game created');
    } else {
      debugPrint(
        '[ConnectFour] _initGame: game already exists, using existing',
      );
    }
  }

  @override
  void dispose() {
    GameState.isPlaying = false;
    GameService.disposeStream(widget.roomId);
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _dropDisc(int column) async {
    _dbg('_dropDisc: column=$column, uid=${currentUser.uid}');
    final stopwatch = Stopwatch()..start();
    final result = await GameService.makeConnectFourMove(
      roomId: widget.roomId,
      column: column,
      currentUserId: currentUser.uid,
    );
    stopwatch.stop();
    _dbg(
      '_dropDisc: committed=$result, latency=${stopwatch.elapsedMilliseconds}ms',
    );
  }

  Future<void> _resetGame() async {
    _dbg('_resetGame: room=${widget.roomId}, uid=${currentUser.uid}');
    await GameService.resetConnectFourGame(
      roomId: widget.roomId,
      currentUserId: currentUser.uid,
    );
    _dbg('_resetGame: done');
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.screenBg,
      appBar: AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primaryText),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Connect Four",
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              "vs ${widget.opponentName}",
              style: TextStyle(color: colors.secondaryText, fontSize: 12),
            ),
          ],
        ),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _gameStream ?? const Stream.empty(),
        builder: (context, snap) {
          _rebuildCount++;
          _dbg('StreamBuilder rebuild #$_rebuildCount');

          if (!snap.hasData) {
            return Center(
              child: CircularProgressIndicator(color: colors.accent),
            );
          }

          final roomData = snap.data!.data() as Map<String, dynamic>?;
          final gameData = roomData?["game"] as Map<String, dynamic>?;

          if (gameData == null || gameData["type"] != "connectfour") {
            return Center(
              child: CircularProgressIndicator(color: colors.accent),
            );
          }

          final board = List<String>.from(gameData["board"] ?? []);
          final currentPlayer = gameData["currentPlayer"] as String?;
          final status = gameData["status"] as String? ?? "playing";
          final winner = gameData["winner"] as String?;
          final winningCells =
              (gameData["winningCells"] as List?)?.cast<int>().toSet() ?? {};

          _dbg(
            'stream: player=$currentPlayer, status=$status, winningCells=${winningCells.length}, boardFilled=${board.where((c) => c.isNotEmpty).length}',
          );
          final isMyTurn = currentPlayer == currentUser.uid;

          return Column(
            children: [
              const SizedBox(height: 16),
              _buildStatusBanner(status, winner, isMyTurn, colors),
              const SizedBox(height: 16),
              _buildLegend(colors, gameData),
              const SizedBox(height: 16),
              _buildBoard(board, isMyTurn, status, winningCells, colors),
              const SizedBox(height: 24),
              if (status != "playing") _buildPlayAgainButton(colors),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusBanner(
    String status,
    String? winner,
    bool isMyTurn,
    AppColors colors,
  ) {
    String message;
    Color color;
    IconData icon;

    if (status == "finished") {
      if (winner == currentUser.uid) {
        message = "🎉 You won!";
        color = const Color(0xFF22C55E);
        icon = Icons.emoji_events;
      } else {
        message = "${widget.opponentName} won!";
        color = const Color(0xFFEF4444);
        icon = Icons.sentiment_dissatisfied_outlined;
      }
    } else if (status == "draw") {
      message = "It's a draw!";
      color = Colors.orange;
      icon = Icons.handshake_outlined;
    } else if (isMyTurn) {
      message = "Your turn";
      color = colors.accent;
      icon = Icons.touch_app_outlined;
    } else {
      message = "${widget.opponentName}'s turn...";
      color = colors.secondaryText;
      icon = Icons.hourglass_empty;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            message,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(AppColors colors, Map<String, dynamic> gameData) {
    // ✅ Determine colors based on which player you are.
    // player1 always plays X (Blue), player2 always plays O (Red).
    // The legend was previously hardcoded to "You=Blue" which was wrong
    // for the second player who joined the game.
    final isPlayer1 = currentUser.uid == gameData["player1Id"];
    final myColor = isPlayer1
        ? const Color(0xFF3B82F6) // Blue for player1
        : const Color(0xFFEF4444); // Red for player2
    final theirColor = isPlayer1
        ? const Color(0xFFEF4444) // Red for opponent of player1
        : const Color(0xFF3B82F6); // Blue for opponent of player2

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _legendDot(myColor, "You", colors),
        const SizedBox(width: 20),
        _legendDot(theirColor, widget.opponentName, colors),
      ],
    );
  }

  Widget _legendDot(Color color, String label, AppColors colors) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 13, color: colors.secondaryText),
        ),
      ],
    );
  }

  Widget _buildBoard(
    List<String> board,
    bool isMyTurn,
    String status,
    Set<int> winningCells,
    AppColors colors,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E3A5F),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drop arrows
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(7, (col) {
              final canDrop = isMyTurn && status == "playing";
              return GestureDetector(
                onTap: () => canDrop ? _dropDisc(col) : null,
                child: SizedBox(
                  width: 40,
                  height: 24,
                  child: canDrop
                      ? Icon(
                          Icons.arrow_drop_down,
                          color: const Color(0xFF3B82F6),
                          size: 28,
                        )
                      : const SizedBox(),
                ),
              );
            }),
          ),
          const SizedBox(height: 4),

          // Grid with winning animation
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 42,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemBuilder: (context, index) {
              final col = index % 7;
              final value = board[index];
              final isEmpty = value.isEmpty;

              // ✅ FIX: Set<int> O(1) lookup — 42 iterations max, no O(n) List.contains
              final isWinning =
                  winningCells.contains(index) && status == "finished";

              return GestureDetector(
                onTap: () =>
                    isMyTurn && status == "playing" ? _dropDisc(col) : null,
                child: isWinning
                    ? _buildWinningCell(value)
                    : Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isEmpty
                              ? const Color(0xFF2A4A7F)
                              : value == "X"
                              ? const Color(0xFF3B82F6)
                              : const Color(0xFFEF4444),
                        ),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ✅ Winning cell with glowing animation
  Widget _buildWinningCell(String value) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = 0.9 + 0.1 * _pulseController.value;
        final glow = 10 + 10 * _pulseController.value;

        return Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value == "X"
                  ? const Color(0xFF3B82F6)
                  : const Color(0xFFEF4444),
              boxShadow: [
                BoxShadow(
                  color: (value == "X" ? Colors.blue : Colors.red).withValues(
                    alpha: 0.8,
                  ),
                  blurRadius: glow,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlayAgainButton(AppColors colors) {
    return Column(
      children: [
        ElevatedButton.icon(
          onPressed: _resetGame,
          icon: const Icon(Icons.replay),
          label: const Text("Play Again"),
          style: ElevatedButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            elevation: 2,
            shadowColor: colors.accent.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back, size: 18, color: colors.secondaryText),
          label: Text(
            "Back to Games",
            style: TextStyle(color: colors.secondaryText),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: colors.borderColor),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
        ),
      ],
    );
  }
}
