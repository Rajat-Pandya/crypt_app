import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../services/game_service.dart';
import '../utils/game_state.dart';
import 'connect_four_screen.dart';
import 'number_guess_screen.dart';

class GameScreen extends StatefulWidget {
  final String roomId;
  final String opponentId;
  final String opponentName;

  const GameScreen({
    super.key,
    required this.roomId,
    required this.opponentId,
    required this.opponentName,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  String? _selectedGame;
  int _tttRebuildCount = 0;
  bool _restarting = false;

  Stream<DocumentSnapshot>? _gameStream;
  bool _isMovePending = false;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[GameScreen] $message');
      return true;
    }());
  }

  @override
  void initState() {
    super.initState();
    GameState.isPlaying = true;
    _gameStream = GameService.gameStream(widget.roomId);
  }

  @override
  void dispose() {
    GameState.isPlaying = false;
    GameService.disposeStream(widget.roomId);
    super.dispose();
  }

  // ✅ FIX #2: Helper to get correct AppBar title
  String get _appBarTitle {
    switch (_selectedGame) {
      case "tictactoe":
        return "Tic Tac Toe";
      case "connectfour":
        return "Connect Four";
      case "numberguess":
        return "Number Guess";
      default:
        return "Games";
    }
  }

  // ✅ FIX #2: Show back button only when in tictactoe (inline game)
  bool get _showBackButton => _selectedGame == "tictactoe";

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final currentUser = FirebaseAuth.instance.currentUser!;

    return Scaffold(
      backgroundColor: colors.screenBg,
      appBar: AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        // ✅ FIX #2: Back button only shows for inline tictactoe
        leading: _showBackButton
            ? IconButton(
                icon: Icon(Icons.arrow_back, color: colors.primaryText),
                onPressed: () => setState(() => _selectedGame = null),
              )
            : null,
        title: Row(
          children: [
            const Text("🎮", style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ✅ FIX #2: Title now correctly reflects all games
                Text(
                  _appBarTitle,
                  style: TextStyle(
                    color: colors.primaryText,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                Text(
                  "vs ${widget.opponentName}",
                  style: TextStyle(color: colors.secondaryText, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
      body:
          (_selectedGame == null ||
              _selectedGame == "connectfour" ||
              _selectedGame == "numberguess")
          ? _buildGamePicker(context, currentUser.uid, colors)
          : _buildTicTacToe(context, currentUser, colors),
    );
  }

  // ── Game Picker ────────────────────────────────────────────────────────────

  Widget _buildGamePicker(
    BuildContext context,
    String currentUserId,
    AppColors colors,
  ) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),

          Text(
            "Choose a Game",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: colors.primaryText,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            "Challenge ${widget.opponentName} to a game!",
            style: TextStyle(fontSize: 14, color: colors.secondaryText),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 32),

          // ── Tic Tac Toe ──
          _GameCard(
            emoji: "❌",
            title: "Tic Tac Toe",
            subtitle: "Classic 3×3 strategy game",
            color: const Color(0xFF3B82F6),
            colors: colors,
            onTap: () {
              debugPrint('[GameScreen] TicTacToe selected');
              // ✅ FIX #1: TicTacToe uses its own game path via GameService
              // GameService writes to chat_rooms/{roomId} "game" field
              // This is isolated from Connect Four's subcollection path
              setState(() {
                _selectedGame = "tictactoe";
                _lastTttGameData = null;
                _cachedTttWidget = null;
              });
              GameService.startGame(
                roomId: widget.roomId,
                currentUserId: currentUserId,
                opponentId: widget.opponentId,
              );
            },
          ),

          const SizedBox(height: 16),

          // In game_screen.dart, update the Connect Four card onTap:
          _GameCard(
            emoji: "🔴",
            title: "Connect Four",
            subtitle: "Drop discs and connect 4 to win!",
            color: const Color(0xFFEF4444),
            colors: colors,
            onTap: () {
              debugPrint('[GameScreen] Connect Four selected');
              setState(() => _selectedGame = "connectfour");
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConnectFourScreen(
                    roomId: widget.roomId,
                    opponentId: widget.opponentId,
                    opponentName: widget.opponentName,
                  ),
                ),
              ).then((_) {
                if (mounted) setState(() => _selectedGame = null);
              });
            },
          ),

          const SizedBox(height: 16),

          // ── Number Guess ──
          _GameCard(
            emoji: "🔢",
            title: "Number Guess",
            subtitle: "Set a number, give hints, outsmart them!",
            color: const Color(0xFF8B5CF6),
            colors: colors,
            onTap: () {
              debugPrint('[GameScreen] Number Guess selected');
              setState(() => _selectedGame = "numberguess");
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NumberGuessScreen(
                    roomId: widget.roomId,
                    opponentId: widget.opponentId,
                    opponentName: widget.opponentName,
                  ),
                ),
              ).then((_) {
                if (mounted) setState(() => _selectedGame = null);
              });
            },
          ),

          const SizedBox(height: 32),

          // ── Back to Chat ──
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.borderColor),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: Icon(
              Icons.chat_bubble_outline,
              size: 18,
              color: colors.secondaryText,
            ),
            label: Text(
              "Back to Chat",
              style: TextStyle(color: colors.secondaryText),
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // ── Tic Tac Toe ────────────────────────────────────────────────────────────

  Map<String, dynamic>? _lastTttGameData;
  Widget? _cachedTttWidget;

  Widget _buildTicTacToe(
    BuildContext context,
    User currentUser,
    AppColors colors,
  ) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _gameStream ?? const Stream.empty(),
      builder: (context, snapshot) {
        _tttRebuildCount++;
        _dbg('TicTacToe StreamBuilder rebuild #$_tttRebuildCount');

        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator(color: colors.accent));
        }

        final roomData = snapshot.data!.data() as Map<String, dynamic>?;
        final gameData = roomData?["game"] as Map<String, dynamic>?;

        if (gameData == null) {
          return Center(child: CircularProgressIndicator(color: colors.accent));
        }

        if (_lastTttGameData != null &&
            _deepEquals(gameData, _lastTttGameData!)) {
          _dbg('gameData unchanged — returning cached widget');
          return _cachedTttWidget!;
        }

        _lastTttGameData = Map<String, dynamic>.from(gameData);

        final board = List<String>.from(gameData["board"]);
        final status = gameData["status"] as String;
        final currentTurn = gameData["currentTurn"] as String;
        final winner = gameData["winner"] as String?;
        final players = List<String>.from(gameData["players"]);

        final isMyTurn = currentTurn == currentUser.uid;
        final mySymbol = players[0] == currentUser.uid ? "X" : "O";
        final opponentSymbol = mySymbol == "X" ? "O" : "X";

        _cachedTttWidget = Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              _buildScoreHeader(
                currentUser.uid,
                mySymbol,
                opponentSymbol,
                isMyTurn,
                status,
                colors,
              ),
              const SizedBox(height: 32),
              _buildStatusBanner(
                status,
                winner,
                currentUser.uid,
                isMyTurn,
                colors,
              ),
              if (_isMovePending) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Move sent, waiting for response...',
                        style: TextStyle(color: Colors.blue.shade700, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 32),
              _buildBoard(
                context,
                board,
                status,
                currentUser.uid,
                colors,
                isMyTurn,
              ),
              const SizedBox(height: 40),
              _buildActions(context, currentUser.uid, status, colors),
            ],
          ),
        );

        return _cachedTttWidget!;
      },
    );
  }

  bool _deepEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      final va = a[key];
      final vb = b[key];
      if (va is List && vb is List) {
        if (va.length != vb.length) return false;
        for (int i = 0; i < va.length; i++) {
          if (va[i] != vb[i]) return false;
        }
      } else if (va != vb) {
        return false;
      }
    }
    return true;
  }

  // ── Score Header ───────────────────────────────────────────────────────────

  Widget _buildScoreHeader(
    String currentUserId,
    String mySymbol,
    String opponentSymbol,
    bool isMyTurn,
    String status,
    AppColors colors,
  ) {
    return Row(
      children: [
        _buildPlayerCard(
          label: "You",
          symbol: mySymbol,
          isActive: isMyTurn && status == "playing",
          color: const Color(0xFF3B82F6),
          colors: colors,
        ),
        Expanded(
          child: Center(
            child: Text(
              "VS",
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: colors.secondaryText,
              ),
            ),
          ),
        ),
        _buildPlayerCard(
          label: widget.opponentName,
          symbol: opponentSymbol,
          isActive: !isMyTurn && status == "playing",
          color: const Color(0xFFEF4444),
          colors: colors,
        ),
      ],
    );
  }

  Widget _buildPlayerCard({
    required String label,
    required String symbol,
    required bool isActive,
    required Color color,
    required AppColors colors,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.12) : colors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? color : colors.borderColor,
          width: isActive ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Text(
            symbol,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isActive ? color : colors.secondaryText,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ── Status Banner ──────────────────────────────────────────────────────────

  Widget _buildStatusBanner(
    String status,
    String? winner,
    String currentUserId,
    bool isMyTurn,
    AppColors colors,
  ) {
    String text;
    Color bgColor;
    Color textColor;

    if (status == "finished") {
      if (winner == currentUserId) {
        text = "🎉 You won!";
        bgColor = Colors.green.withValues(alpha: 0.15);
        textColor = Colors.green;
      } else {
        text = "😔 ${widget.opponentName} won";
        bgColor = Colors.red.withValues(alpha: 0.12);
        textColor = Colors.red;
      }
    } else if (status == "draw") {
      text = "🤝 It's a draw!";
      bgColor = Colors.orange.withValues(alpha: 0.12);
      textColor = Colors.orange;
    } else {
      text = isMyTurn ? "Your turn" : "${widget.opponentName}'s turn";
      bgColor = isMyTurn
          ? colors.accent.withValues(alpha: 0.1)
          : colors.inputBg;
      textColor = isMyTurn ? colors.accent : colors.secondaryText;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    );
  }

  // ── Board ──────────────────────────────────────────────────────────────────

  Widget _buildBoard(
    BuildContext context,
    List<String> board,
    String status,
    String currentUserId,
    AppColors colors,
    bool isMyTurn,
  ) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: colors.cardBg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 9,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemBuilder: (context, index) {
            final cell = board[index];
            final isEmpty = cell.isEmpty;
            final isX = cell == "X";

            return GestureDetector(
              onTap: (status == "playing" && isMyTurn && isEmpty)
                  ? () async {
                      if (_isMovePending) return;
                      setState(() {
                        _isMovePending = true;
                        _lastTttGameData = null;
                        _cachedTttWidget = null;
                      });
                      await GameService.makeMove(
                        roomId: widget.roomId,
                        index: index,
                        currentUserId: currentUserId,
                      );
                      if (mounted) setState(() => _isMovePending = false);
                    }
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isEmpty
                      ? colors.inputBg
                      : isX
                      ? const Color(0xFF3B82F6).withValues(alpha: 0.12)
                      : const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isEmpty
                        ? colors.borderColor
                        : isX
                        ? const Color(0xFF3B82F6)
                        : const Color(0xFFEF4444),
                    width: isEmpty ? 1 : 2,
                  ),
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, animation) =>
                        ScaleTransition(scale: animation, child: child),
                    child: Text(
                      cell,
                      key: ValueKey(cell + index.toString()),
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: isX
                            ? const Color(0xFF3B82F6)
                            : const Color(0xFFEF4444),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Widget _buildActions(
    BuildContext context,
    String currentUserId,
    String status,
    AppColors colors,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(status == "playing" ? "Restart" : "Play Again"),
          onPressed: () async {
            if (_restarting) return;
            setState(() => _restarting = true);
            await GameService.startGame(
              roomId: widget.roomId,
              currentUserId: currentUserId,
              opponentId: widget.opponentId,
            );
            if (mounted) setState(() => _restarting = false);
          },
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.secondaryText,
            side: BorderSide(color: colors.borderColor),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: Icon(
            Icons.grid_view_rounded,
            size: 18,
            color: colors.secondaryText,
          ),
          label: Text(
            "Game Menu",
            style: TextStyle(color: colors.secondaryText),
          ),
          onPressed: () => setState(() => _selectedGame = null),
        ),
      ],
    );
  }
}

// ── Game Card Widget ───────────────────────────────────────────────────────

class _GameCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Color color;
  final AppColors colors;
  final VoidCallback onTap;

  const _GameCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Emoji container
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
            const SizedBox(width: 16),

            // Title + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: colors.primaryText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 13, color: colors.secondaryText),
                  ),
                ],
              ),
            ),

            // Chevron
            Icon(Icons.chevron_right_rounded, color: color, size: 26),
          ],
        ),
      ),
    );
  }
}
