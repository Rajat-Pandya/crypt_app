import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/game_state.dart';
import '../main.dart';
import '../services/game_service.dart';
import '../services/multiplayer_service.dart';

// ─── Constants ────────────────────────────────────────────────────────────────

const int kCols = 7;
const int kRows = 6;
const double kGravity = 2.0;       // px/frame acceleration (faster drop)
const double kDamping = 0.42;      // velocity multiplier on bounce
const double kMinBounceVel = 1.5;  // below this speed, stop bouncing
const int kMaxBounces = 3;         // hard cap on number of bounces

// ─── Player colours ───────────────────────────────────────────────────────────

const List<Color> kPieceFill = [
  Color(0xFF3B82F6), // Player 1 - Blue
  Color(0xFFEF4444), // Player 2 - Red
];
const List<Color> kPieceHighlight = [
  Color(0xFF93C5FD),
  Color(0xFFFCA5A5),
];

// ─── AnimatingBall model ──────────────────────────────────────────────────────

class AnimatingBall {
  final int col;
  final int targetRow;
  final int player;
  double x;
  double y;
  double vy;
  int bounceCount;
  bool settled;

  AnimatingBall({
    required this.col,
    required this.targetRow,
    required this.player,
    required this.x,
    required this.y,
  })  : vy = 0,
        bounceCount = 0,
        settled = false;
}

// ─── ConnectFourScreen widget ───────────────────────────────────────────────────

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

  late final MultiplayerService _multiplayerService;
  Stream<Map<String, dynamic>?>? _gameStateStream;

  // Session score tracker
  int _myWins = 0;
  int _opponentWins = 0;
  String? _lastStatus;

  // Board: -1 = empty, 0 = Player 0, 1 = Player 1
  late List<List<int>> _board;
  int _currentPlayer = 0;  // Whose turn it is (0 or 1)
  int _myPlayer = 0;       // Which player number the current user is (0 or 1)
  bool _gameOver = false;
  bool _isAnimating = false;
  AnimatingBall? _activeBall;
  List<Point<int>>? _winningCells;

  // Winning-ring pulse animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  // Physics ticker
  Ticker? _ticker;

  // Cell size is computed dynamically from available width
  double _cellSize = 50.0;

  // Cached state
  List<String> _lastBoard = [];
  Set<int> _lastWinningCells = {};
  int _lastMoveTimestamp = 0;  // Track last move to avoid duplicate animations
  
  // Animation completion
  Completer<void>? _animationCompleter;
  
  // Track currently animating cell to prevent double-drawing
  Point<int>? _animatingCell;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[ConnectFour] $message');
      return true;
    }());
  }

  @override
  void initState() {
    super.initState();
    _dbg('initState: START');
    GameState.enter();
    _initBoard();
    _multiplayerService = MultiplayerService();
    _multiplayerService.initialize(currentUser.uid);
    _gameStateStream = _multiplayerService.joinRoom(widget.roomId);
    _initGame();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _ticker = createTicker(_onTick);
    _dbg('initState: END');
  }

  @override
  void dispose() {
    GameState.leave();
    _multiplayerService.leaveRoom();
    _ticker?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _initGame() async {
    if (_initStarted) return;
    _initStarted = true;

    final snap = await FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(widget.roomId)
        .get();

    final gameData = (snap.data()?['game']) as Map<String, dynamic>?;
    if (gameData == null || gameData['type'] != 'connectfour') {
      await GameService.startConnectFourGame(
        roomId: widget.roomId,
        currentUserId: currentUser.uid,
        opponentId: widget.opponentId,
      );
    }
  }

  // ── Board helpers ────────────────────────────────────────────────────────────

  void _initBoard() {
    _board = List.generate(kRows, (_) => List.filled(kCols, -1));
    _currentPlayer = 0;
    _gameOver = false;
    _isAnimating = false;
    _activeBall = null;
    _winningCells = null;
  }

  void _updateBoardState(List<String> board) {
    _dbg('_updateBoardState: START boardLength=${board.length}');
    for (int row = 0; row < kRows; row++) {
      for (int col = 0; col < kCols; col++) {
        final index = row * kCols + col;
        if (index < board.length && board[index].isNotEmpty) {
          _board[row][col] = board[index] == 'X' ? 0 : 1;
        } else {
          _board[row][col] = -1;
        }
      }
    }
  }

  // Search from bottom up (row 0 = bottom, row 5 = top)
  int _getDropRow(int col) {
    for (int r = 0; r < kRows; r++) {
      if (_board[r][col] == -1) return r;
    }
    return -1; // Column full
  }

  // Check for 4-in-a-row starting from (r, c) for player p
  List<Point<int>>? _checkWin(int r, int c, int p) {
    const dirs = [
      [0, 1],  // horizontal
      [1, 0],  // vertical
      [1, 1],  // diagonal ↘
      [1, -1], // anti-diagonal ↙
    ];
    for (final d in dirs) {
      final cells = <Point<int>>[Point(r, c)];
      for (final s in [-1, 1]) {
        int nr = r + d[0] * s, nc = c + d[1] * s;
        while (nr >= 0 && nr < kRows && nc >= 0 && nc < kCols && _board[nr][nc] == p) {
          cells.add(Point(nr, nc));
          nr += d[0] * s;
          nc += d[1] * s;
        }
      }
      if (cells.length >= 4) return cells;
    }
    return null;
  }

  bool _checkDraw() => _board[0].every((c) => c != -1);

  // ── Drop logic ───────────────────────────────────────────────────────────────

  Future<void> _dropPiece(int col) async {
    if (_isAnimating || _gameOver) return;

    final row = _getDropRow(col);
    if (row == -1) return;

    HapticFeedback.selectionClick();

    final startX = col * _cellSize + _cellSize / 2;  // Centered over tapped column
    final startY = -_cellSize * 0.5;  // Start just above the board header area

    setState(() {
      _isAnimating = true;
      _animatingCell = Point(row, col);  // Track which cell we're animating
      _activeBall = AnimatingBall(
        col: col,
        targetRow: row,
        player: _myPlayer,  // Use the current user's player color, not whose turn it is
        x: startX,
        y: startY,
      );
    });

    if (!_ticker!.isActive) {
      _ticker!.start();
    }

    // Commit to Firestore immediately (don't wait for animation)
    // This reduces delay for the opponent
    final moveFuture = GameService.makeConnectFourMove(
      roomId: widget.roomId,
      column: col,
      currentUserId: currentUser.uid,
    );

    // Wait for animation to complete using completer
    _animationCompleter = Completer<void>();
    await _animationCompleter!.future;

    // Wait for Firestore commit to complete (catch any errors)
    try {
      await moveFuture;
    } catch (e) {
      debugPrint('[ConnectFour] Move failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          // Set the piece on the board immediately so it appears after animation
          // (Firestore update might be slightly delayed)
          _board[row][col] = _myPlayer;
          _activeBall = null;
          _isAnimating = false;
          _animatingCell = null;  // Clear animating cell
        });
      }
    }
  }

  // Animate opponent's move received from Firestore
  Future<void> _animateOpponentMove(int col, int row, int player) async {
    if (_isAnimating) return;
    
    _dbg('Animating opponent move: col=$col, row=$row, player=$player');
    
    final startX = col * _cellSize + _cellSize / 2;  // Centered over column
    final startY = -_cellSize * 0.5;  // Start just above the board header area
    
    setState(() {
      _isAnimating = true;
      _animatingCell = Point(row, col);  // Track which cell we're animating
      _activeBall = AnimatingBall(
        col: col,
        targetRow: row,
        player: player,
        x: startX,
        y: startY,
      );
    });
    
    if (!_ticker!.isActive) {
      _ticker!.start();
    }
    
    // Wait for animation to complete using completer
    _animationCompleter = Completer<void>();
    await _animationCompleter!.future;
    
    if (mounted) {
      setState(() {
        // Restore the piece to the board after animation
        _board[row][col] = player;
        _activeBall = null;
        _isAnimating = false;
        _animatingCell = null;  // Clear animating cell
      });
    }
  }

  // ── Physics tick ─────────────────────────────────────────────────────────────

  void _onTick(Duration _) {
    final ball = _activeBall;
    if (ball == null || ball.settled) return;

    // Calculate target Y based on target row
    // The board drawing area starts at y = _cellSize (header row for disc drop preview)
    // targetRow 0 (bottom) -> Y at bottom of board = _cellSize + kRows * _cellSize - 0.5 * _cellSize
    // targetRow 5 (top) -> Y at top of board = _cellSize + 0.5 * _cellSize
    final boardBottomY = _cellSize + kRows * _cellSize;
    final targetY = boardBottomY - (ball.targetRow + 0.5) * _cellSize;

    ball.vy += kGravity;
    ball.y += ball.vy;

    if (ball.y >= targetY) {
      ball.y = targetY;
      final speed = ball.vy.abs();
      ball.bounceCount++;

      if (speed < kMinBounceVel || ball.bounceCount >= kMaxBounces) {
        ball.settled = true;
        _ticker!.stop();
        HapticFeedback.mediumImpact();
        // Signal animation completion
        _animationCompleter?.complete();
      } else {
        ball.vy = -ball.vy * kDamping;
      }
    }

    setState(() {});
  }

  // ── Reset game ───────────────────────────────────────────────────────────────

  Future<void> _resetGame() async {
    _dbg('═══════════════════════════════════════════════════');
    _dbg('_resetGame: START - clearing all state');
    _dbg('═══════════════════════════════════════════════════');

    _ticker!.stop();

    if (mounted) {
      setState(() {
        _activeBall = null;
        _isAnimating = false;
        _winningCells = null;
      });
    }

    _initBoard();
    _dbg('_resetGame: cleared all board cells');

    await GameService.resetConnectFourGame(
      roomId: widget.roomId,
      currentUserId: currentUser.uid,
    );

    _dbg('_resetGame: END - Firestore reset complete');
  }

  Future<void> _showResetConfirmationDialog() async {
    final colors = AppColors.of(context);
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.cardBg,
        title: Text('Reset Game?', style: TextStyle(color: colors.primaryText)),
        content: Text(
          'This will clear the board and start a new game.',
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: colors.secondaryText)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (result == true) {
      await _resetGame();
    }
  }

  // ── Status text ──────────────────────────────────────────────────────────────

  String get _statusText {
    if (_gameOver) {
      if (_winningCells != null) {
        final winner = _board[_winningCells!.first.x][_winningCells!.first.y];
        if (winner == 0) return '🎉 You won!';
        return '${widget.opponentName} won!';
      }
      return "🤝 It's a draw!";
    }
    final isMyTurn = _currentPlayer == 0;
    return isMyTurn ? 'Your turn' : "${widget.opponentName}'s turn...";
  }

  Color get _statusColor {
    if (_gameOver) {
      if (_winningCells != null) {
        final winner = _board[_winningCells!.first.x][_winningCells!.first.y];
        return winner == 0 ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
      }
      return Colors.orange;
    }
    return _currentPlayer == 0 ? const Color(0xFF3B82F6) : const Color(0xFFEF4444);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

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
            Text('Connect Four', style: TextStyle(color: colors.primaryText, fontSize: 16, fontWeight: FontWeight.w600)),
            Text('vs ${widget.opponentName}', style: TextStyle(color: colors.secondaryText, fontSize: 12)),
          ],
        ),
      ),
      body: StreamBuilder<Map<String, dynamic>?>(
        stream: _gameStateStream ?? const Stream.empty(),
        builder: (context, snap) {
          if (!snap.hasData || snap.data == null) {
            return Center(child: CircularProgressIndicator(color: colors.accent));
          }

          final gameData = snap.data!;
          if (gameData['type'] != 'connectfour') {
            return Center(child: CircularProgressIndicator(color: colors.accent));
          }

          final board = List<String>.from(gameData['board'] ?? []);
          final currentPlayer = gameData['currentPlayer'] as String?;
          final status = gameData['status'] as String? ?? 'playing';
          final winner = gameData['winner'] as String?;
          final winningCells = (gameData['winningCells'] as List?)?.cast<int>().toSet() ?? {};
          final player1Id = gameData['player1Id'] as String?;

          _currentPlayer = (currentPlayer == currentUser.uid) ? 0 : 1;
          _myPlayer = (currentUser.uid == player1Id) ? 0 : 1;  // Player 1 is blue (0), Player 2 is red (1)
          _gameOver = status == 'finished' || status == 'draw';

          // Check for opponent's move BEFORE updating board
          // so we can decide whether to animate or just show the settled piece
          final lastMove = gameData['lastMove'] as Map<String, dynamic>?;
          bool shouldAnimateOpponentMove = false;
          int? moveCol, moveRow, movePlayer;
          
          if (lastMove != null && !_isAnimating && !_gameOver) {
            final movePlayerId = lastMove['playerId'] as String?;
            moveCol = lastMove['column'] as int?;
            moveRow = lastMove['row'] as int?;
            final moveTimestamp = lastMove['timestamp'] as int?;
            
            // Only animate if:
            // 1. It's the other player's move
            // 2. We haven't seen this timestamp yet
            // 3. Move is recent (within last 10 seconds)
            // 4. The cell is currently empty in our local board
            if (movePlayerId != null && 
                moveCol != null && 
                moveRow != null &&
                moveTimestamp != null &&
                movePlayerId != currentUser.uid && 
                moveTimestamp != _lastMoveTimestamp) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final isRecent = (now - moveTimestamp) < 10000; // 10 seconds
              final cellEmpty = _board[moveRow][moveCol] == -1;
              
              if (isRecent && cellEmpty) {
                shouldAnimateOpponentMove = true;
                movePlayer = movePlayerId == player1Id ? 0 : 1;
                _lastMoveTimestamp = moveTimestamp;
              }
            }
          }
          
          _updateBoardState(board);
          
          // Trigger opponent animation after board update
          // but temporarily hide the piece that will be animated
          if (shouldAnimateOpponentMove && moveCol != null && moveRow != null && movePlayer != null) {
            final targetCol = moveCol;
            final targetRow = moveRow;
            final targetPlayer = movePlayer;
            // Defer state update to avoid calling setState during build
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                // Temporarily clear the cell so we can animate the ball falling into it
                setState(() {
                  _board[targetRow][targetCol] = -1;
                });
                // Trigger animation
                _animateOpponentMove(targetCol, targetRow, targetPlayer);
              }
            });
          }

          // Convert winning cells from flat index to Point
          if (winningCells.isNotEmpty) {
            _winningCells = winningCells.map((idx) {
              final row = idx ~/ kCols;
              final col = idx % kCols;
              return Point(row, col);
            }).toList();
          } else {
            _winningCells = null;
          }

          // Update session score
          if (status == 'finished' && _lastStatus == 'playing') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  if (winner == currentUser.uid) _myWins++;
                  else _opponentWins++;
                });
              }
            });
          }
          _lastStatus = status;

          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 16),
              // Status bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: _statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: _statusColor.withOpacity(0.3)),
                ),
                child: Text(
                  _statusText,
                  style: TextStyle(color: _statusColor, fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
              const SizedBox(height: 8),
              // Score display
              Center(
                child: Column(
                  children: [
                    Text(
                      '$_myWins - $_opponentWins',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: colors.primaryText),
                    ),
                    Text('VS', style: TextStyle(fontSize: 12, color: colors.secondaryText)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Legend
              _buildLegend(player1Id),
              const SizedBox(height: 24),
              // Board
              _buildBoard(colors, currentUser.uid, player1Id),
              const SizedBox(height: 16),
              // Reset button (always visible during gameplay)
              if (!_gameOver) 
                TextButton.icon(
                  onPressed: () => _showResetConfirmationDialog(),
                  icon: Icon(Icons.replay_outlined, size: 18, color: colors.accent),
                  label: Text(
                    'Reset Game',
                    style: TextStyle(color: colors.accent, fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: colors.accent.withOpacity(0.3)),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (_gameOver) _buildPlayAgainButton(colors),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLegend(String? player1Id) {
    final isPlayer1 = currentUser.uid == player1Id;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _legendItem(isPlayer1 ? kPieceFill[0] : kPieceFill[1], 'You'),
        const SizedBox(width: 24),
        _legendItem(isPlayer1 ? kPieceFill[1] : kPieceFill[0], widget.opponentName),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
      ],
    );
  }

  Widget _buildBoard(AppColors colors, String currentUserId, String? player1Id) {
    final isMyTurn = _currentPlayer == 0 && !_gameOver && !_isAnimating;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _cellSize = constraints.maxWidth / kCols;
          final boardHeight = _cellSize * (kRows + 1);

          return GestureDetector(
            onTapDown: (details) {
              if (!isMyTurn || _isAnimating || _gameOver) return;
              final col = (details.localPosition.dx / _cellSize).floor();
              if (col >= 0 && col < kCols) _dropPiece(col);
            },
            child: AnimatedBuilder(
              animation: _pulseAnim,
              builder: (context, _) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, boardHeight),
                  painter: _BoardPainter(
                    board: _board,
                    cellSize: _cellSize,
                    activeBall: _activeBall,
                    winningCells: _winningCells,
                    pulseOpacity: _pulseAnim.value,
                    animatingCell: _animatingCell,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlayAgainButton(AppColors colors) {
    return Column(
      children: [
        ElevatedButton.icon(
          onPressed: _resetGame,
          icon: const Icon(Icons.replay),
          label: const Text('Play Again'),
          style: ElevatedButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back, size: 18, color: colors.secondaryText),
          label: Text('Back to Games', style: TextStyle(color: colors.secondaryText)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: colors.borderColor),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ],
    );
  }
}

// ─── Board CustomPainter ──────────────────────────────────────────────────────

class _BoardPainter extends CustomPainter {
  final List<List<int>> board;
  final double cellSize;
  final AnimatingBall? activeBall;
  final List<Point<int>>? winningCells;
  final double pulseOpacity;
  final Point<int>? animatingCell;  // Cell currently being animated (don't draw settled piece here)

  const _BoardPainter({
    required this.board,
    required this.cellSize,
    required this.activeBall,
    required this.winningCells,
    required this.pulseOpacity,
    this.animatingCell,
  });

  double get radius => cellSize * 0.4;

  // Inverted: row 0 is at the bottom, row 5 is at the top
  // Board drawing area starts at y = cellSize (header row for disc drop)
  Offset cellCenter(int row, int col) {
    // x: center of column
    final x = col * cellSize + cellSize / 2;
    // y: position from bottom (row 0 = bottom of board area)
    final boardBottomY = cellSize + kRows * cellSize;
    final y = boardBottomY - (row + 0.5) * cellSize;
    return Offset(x, y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _drawBoard(canvas, size);
    _drawSettledPieces(canvas);
    _drawActiveBall(canvas);
    _drawWinningRings(canvas);
  }

  void _drawBoard(Canvas canvas, Size size) {
    final boardRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, cellSize, size.width, size.height - cellSize),
      const Radius.circular(12),
    );
    canvas.drawRRect(boardRect, Paint()..color = const Color(0xFF1B4FA8));

    final holePaint = Paint()..color = const Color(0xFF0D1F3C);
    for (int r = 0; r < kRows; r++) {
      for (int c = 0; c < kCols; c++) {
        if (board[r][c] == -1) {
          canvas.drawCircle(cellCenter(r, c), radius, holePaint);
        }
      }
    }
  }

  void _drawSettledPieces(Canvas canvas) {
    for (int r = 0; r < kRows; r++) {
      for (int c = 0; c < kCols; c++) {
        // Skip the cell currently being animated
        final cell = animatingCell;
        if (cell != null && cell.x == r && cell.y == c) {
          continue;
        }
        final p = board[r][c];
        if (p != -1) {
          _drawPiece(canvas, cellCenter(r, c), p);
        }
      }
    }
  }

  void _drawPiece(Canvas canvas, Offset center, int player,
      {double scaleX = 1.0, double scaleY = 1.0}) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scaleX, scaleY);

    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()..color = kPieceFill[player],
    );

    canvas.drawCircle(
      Offset(-radius * 0.25, -radius * 0.3),
      radius * 0.3,
      Paint()..color = kPieceHighlight[player].withOpacity(0.5),
    );

    canvas.restore();
  }

  void _drawActiveBall(Canvas canvas) {
    final ball = activeBall;
    if (ball == null) return;

    final speed = ball.vy.abs();
    final scaleY = 1.0 + speed * 0.012;
    final scaleX = 1.0 - speed * 0.006;

    _drawPiece(
      canvas,
      Offset(ball.x, ball.y),
      ball.player,
      scaleX: scaleX,
      scaleY: scaleY,
    );
  }

  void _drawWinningRings(Canvas canvas) {
    final cells = winningCells;
    if (cells == null) return;

    final ringPaint = Paint()
      ..color = Colors.white.withOpacity(pulseOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (final pt in cells) {
      canvas.drawCircle(cellCenter(pt.x, pt.y), radius + 2, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.activeBall != activeBall ||
      old.pulseOpacity != pulseOpacity ||
      old.winningCells != winningCells ||
      old.board != board;
}
