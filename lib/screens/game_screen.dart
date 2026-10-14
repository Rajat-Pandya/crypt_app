import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../services/game_service.dart';
import '../services/multiplayer_service.dart';
import '../utils/game_state.dart';
import '../services/startup_task_scheduler.dart';
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

  bool _isMovePending = false;
  
  // Turn timer
  Timer? _turnTimer;
  int _secondsLeft = 60;
  
  // Session score tracker (local state, persists across restarts)
  int _myWins = 0;
  int _opponentWins = 0;
  String? _lastStatus;
  
  // MultiplayerService for centralized stream ownership
  late final MultiplayerService _multiplayerService;
  Stream<Map<String, dynamic>?>? _gameStateStream;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[GameScreen] $message');
      return true;
    }());
  }

  @override
  void initState() {
    super.initState();
    GameState.enter();
    
    // Initialize MultiplayerService for centralized stream management
    _multiplayerService = MultiplayerService();
    _initializeMultiplayer();
  }
  
  void _initializeMultiplayer() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      _multiplayerService.initialize(currentUser.uid);
      _gameStateStream = _multiplayerService.joinRoom(widget.roomId);
      _dbg('Multiplayer initialized for room: ${widget.roomId}');
    }
  }

  @override
  void dispose() {
    GameState.leave();
    // Proper dispose via MultiplayerService (centralized ownership)
    _multiplayerService.leaveRoom();
    _turnTimer?.cancel();
    super.dispose();
  }

  // ✅ FIX #2: Helper to get correct AppBar title
  String get _appBarTitle {
    switch (_selectedGame) {
      case 'tictactoe':
        return 'Tic Tac Toe';
      case 'connectfour':
        return 'Connect Four';
      case 'numberguess':
        return 'Number Guess';
      default:
        return 'Games';
    }
  }

  // ✅ FIX #2: Show back button only when in tictactoe (inline game)
  bool get _showBackButton => _selectedGame == 'tictactoe';

  // Turn timer methods
  void _startTurnTimer(bool isMyTurn) {
    _turnTimer?.cancel();
    if (!isMyTurn) {
      // Use microtask to avoid setState during build
      Future.microtask(() {
        if (mounted) {
          setState(() => _secondsLeft = 60);
        }
      });
      return;
    }
    _turnTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        t.cancel();
        // Auto-forfeit: call GameService to end game with opponent as winner
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) {
          GameService.forfeitGame(
            roomId: widget.roomId,
            currentUserId: currentUser.uid,
          );
        }
      }
    });
  }

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
            const Text('🎮', style: TextStyle(fontSize: 20)),
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
                  'vs ${widget.opponentName}',
                  style: TextStyle(color: colors.secondaryText, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
      body:
          (_selectedGame == null ||
              _selectedGame == 'connectfour' ||
              _selectedGame == 'numberguess')
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
            'Choose a Game',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: colors.primaryText,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Challenge ${widget.opponentName} to a game!',
            style: TextStyle(fontSize: 14, color: colors.secondaryText),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 32),

          // ── Tic Tac Toe ──
          _GameCard(
            emoji: '❌',
            title: 'Tic Tac Toe',
            subtitle: 'Classic 3×3 strategy game',
            color: const Color(0xFF3B82F6),
            colors: colors,
            onTap: () async {
              debugPrint('[GameScreen] TicTacToe selected');
              // ✅ FIX #1: TicTacToe uses its own game path via GameService
              // GameService writes to chat_rooms/{roomId} "game" field
              // This is isolated from Connect Four's subcollection path
              setState(() {
                _selectedGame = 'tictactoe';
                _lastTttGameData = null;
                _cachedTttWidget = null;
              });
              
              // Ensure MultiplayerService stream is active before starting game
              if (_gameStateStream == null) {
                _initializeMultiplayer();
              }
              
              // Wait for game to be created in Firestore
              await GameService.startGame(
                roomId: widget.roomId,
                currentUserId: currentUserId,
                opponentId: widget.opponentId,
                type: 'tictactoe',
              );
              debugPrint('[GameScreen] TicTacToe game created');
            },
          ),

          const SizedBox(height: 16),

          // In game_screen.dart, update the Connect Four card onTap:
          _GameCard(
            emoji: '🔴',
            title: 'Connect Four',
            subtitle: 'Drop discs and connect 4 to win!',
            color: const Color(0xFFEF4444),
            colors: colors,
            onTap: () {
              debugPrint('[GameScreen] Connect Four selected');
              setState(() => _selectedGame = 'connectfour');
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
            emoji: '🔢',
            title: 'Number Guess',
            subtitle: 'Set a number, give hints, outsmart them!',
            color: const Color(0xFF8B5CF6),
            colors: colors,
            onTap: () {
              debugPrint('[PERF] Number Guess selected');
              setState(() => _selectedGame = 'numberguess');
              
              // ✅ FIX: Pause background tasks for smooth navigation
              StartupTaskScheduler.pauseBackgroundTasks();
              debugPrint('[PERF] Background tasks paused for navigation');
              
              debugPrint('[NG_ROUTE] Starting navigation to NumberGuessScreen...');
              debugPrint('[NG_ROUTE] roomId=${widget.roomId}, opponentId=${widget.opponentId}');
              
              try {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) {
                      debugPrint('[NG_ROUTE] MaterialPageRoute.builder executing');
                      debugPrint('[NG_ROUTE] Creating NumberGuessScreen widget');
                      return NumberGuessScreen(
                        roomId: widget.roomId,
                        opponentId: widget.opponentId,
                        opponentName: widget.opponentName,
                      );
                    },
                  ),
                ).then((result) {
                  debugPrint('[NG_ROUTE] Navigator.push returned with result: $result');
                  // Resume background tasks when returning
                  StartupTaskScheduler.resumeBackgroundTasks();
                  debugPrint('[PERF] Background tasks resumed');
                  if (mounted) setState(() => _selectedGame = null);
                });
                debugPrint('[NG_ROUTE] Navigator.push called successfully');
              } catch (e, stackTrace) {
                debugPrint('[NG_ROUTE] ERROR during navigation: $e');
                StartupTaskScheduler.resumeBackgroundTasks();
                debugPrint('[PERF] Background tasks resumed (error)');
                debugPrint('[NG_ROUTE] Stack trace: $stackTrace');
              }
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
              'Back to Chat',
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
    // Use MultiplayerService stream instead of direct Firestore
    return StreamBuilder<Map<String, dynamic>?>(
      stream: _gameStateStream ?? const Stream.empty(),
      builder: (context, snapshot) {
        _tttRebuildCount++;
        _dbg('TicTacToe StreamBuilder rebuild #$_tttRebuildCount');

        if (!snapshot.hasData || snapshot.data == null) {
          _dbg('TicTacToe: No data yet, showing loading...');
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: colors.accent),
                const SizedBox(height: 16),
                Text(
                  'Loading game...',
                  style: TextStyle(color: colors.secondaryText, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Text(
                  'Room: ${widget.roomId.substring(0, 8)}...',
                  style: TextStyle(color: colors.secondaryText.withValues(alpha: 0.5), fontSize: 12),
                ),
              ],
            ),
          );
        }
        
        _dbg('TicTacToe: Received game data: ${snapshot.data}');

        final gameData = snapshot.data!;

        if (_lastTttGameData != null &&
            _deepEquals(gameData, _lastTttGameData!)) {
          _dbg('gameData unchanged — returning cached widget');
          return _cachedTttWidget!;
        }

        _lastTttGameData = Map<String, dynamic>.from(gameData);

        final board = List<String>.from(gameData['board'] ?? []);
        final status = gameData['status'] as String? ?? 'playing';
        final currentTurn = gameData['currentTurn'] as String?;
        final winner = gameData['winner'] as String?;
        final players = List<String>.from(gameData['players'] ?? []);
        
        if (players.isEmpty) {
          return Center(child: CircularProgressIndicator(color: colors.accent));
        }

        final isMyTurn = currentTurn != null && currentTurn == currentUser.uid;
        final mySymbol = players[0] == currentUser.uid ? 'X' : 'O';
        final opponentSymbol = mySymbol == 'X' ? 'O' : 'X';
        
        // Detect game-end transitions and update session score
        if (status == 'finished' && _lastStatus == 'playing') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                if (winner == currentUser.uid) {
                  _myWins++;
                } else {
                  _opponentWins++;
                }
              });
            }
          });
        }
        _lastStatus = status;
        
        // Start/stop turn timer based on turn
        // Defer to avoid setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _startTurnTimer(isMyTurn);
          }
        });

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
                gameData,
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
          label: 'You',
          symbol: mySymbol,
          isActive: isMyTurn && status == 'playing',
          color: const Color(0xFF3B82F6),
          colors: colors,
        ),
        Expanded(
          child: Center(
            child: Column(
              children: [
                Text(
                  '$_myWins - $_opponentWins',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: colors.primaryText,
                  ),
                ),
                Text(
                  'VS',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildPlayerCard(
          label: widget.opponentName,
          symbol: opponentSymbol,
          isActive: !isMyTurn && status == 'playing',
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

    if (status == 'finished') {
      if (winner == currentUserId) {
        text = '🎉 You won!';
        bgColor = Colors.green.withValues(alpha: 0.15);
        textColor = Colors.green;
      } else {
        text = '😔 ${widget.opponentName} won';
        bgColor = Colors.red.withValues(alpha: 0.12);
        textColor = Colors.red;
      }
    } else if (status == 'draw') {
      text = "🤝 It's a draw!";
      bgColor = Colors.orange.withValues(alpha: 0.12);
      textColor = Colors.orange;
    } else {
      text = isMyTurn ? 'Your turn ($_secondsLeft s)' : "${widget.opponentName}'s turn";
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
    Map<String, dynamic> gameData,
  ) {
    final winningCells = (gameData['winningCells'] as List?)?.cast<int>().toSet() ?? {};
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
            final isX = cell == 'X';
            // Only show winning cells highlight when game is actually finished
            final isWinningCell = status == 'finished' && winningCells.contains(index);

            return GestureDetector(
              onTap: (status == 'playing' && isMyTurn && isEmpty)
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
                duration: const Duration(milliseconds: 400),
                decoration: BoxDecoration(
                  color: isWinningCell
                      ? Colors.green.withValues(alpha: 0.25)
                      : isEmpty
                          ? colors.inputBg
                          : isX
                              ? const Color(0xFF3B82F6).withValues(alpha: 0.12)
                              : const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isWinningCell
                        ? Colors.green
                        : isEmpty
                            ? colors.borderColor.withValues(alpha: 0.4)
                            : isX
                                ? const Color(0xFF3B82F6)
                                : const Color(0xFFEF4444),
                    width: isWinningCell ? 2.5 : (isEmpty ? 1.0 : 2.0),
                  ),
                  boxShadow: isWinningCell
                      ? [BoxShadow(color: Colors.green.withValues(alpha: 0.4), blurRadius: 12)]
                      : null,
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    transitionBuilder: (child, animation) {
                      return ScaleTransition(
                        scale: CurvedAnimation(
                          parent: animation,
                          curve: Curves.elasticOut,  // bouncy feel
                        ),
                        child: child,
                      );
                    },
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
          label: Text(status == 'playing' ? 'Restart' : 'Play Again'),
          onPressed: () async {
            if (_restarting) return;
            setState(() => _restarting = true);
            
            // Clear cached game data to force rebuild with fresh state
            _lastTttGameData = null;
            _cachedTttWidget = null;
            _lastStatus = null;
            
            await GameService.startGame(
              roomId: widget.roomId,
              currentUserId: currentUserId,
              opponentId: widget.opponentId,
              type: 'tictactoe',
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
            'Game Menu',
            style: TextStyle(color: colors.secondaryText),
          ),
          onPressed: () => setState(() => _selectedGame = null),
        ),
      ],
    );
  }
}

// ── Game Card Widget ───────────────────────────────────────────────────────

class _GameCard extends StatefulWidget {
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
  State<_GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<_GameCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: widget.colors.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: widget.color.withValues(alpha: 0.3)),
            boxShadow: _pressed
                ? []
                : [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.08),
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
                  color: widget.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(widget.emoji, style: const TextStyle(fontSize: 28)),
                ),
              ),
              const SizedBox(width: 16),

              // Title + subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: widget.colors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.subtitle,
                      style: TextStyle(fontSize: 13, color: widget.colors.secondaryText),
                    ),
                  ],
                ),
              ),

              // Chevron
              Icon(Icons.chevron_right_rounded, color: widget.color, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}
