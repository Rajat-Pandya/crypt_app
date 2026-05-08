import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart';
import '../services/game_service.dart';
import '../utils/game_state.dart';

class NumberGuessScreen extends StatefulWidget {
  final String roomId;
  final String opponentId;
  final String opponentName;

  const NumberGuessScreen({
    super.key,
    required this.roomId,
    required this.opponentId,
    required this.opponentName,
  });

  @override
  State<NumberGuessScreen> createState() => _NumberGuessScreenState();
}

class _NumberGuessScreenState extends State<NumberGuessScreen> {
  final currentUser = FirebaseAuth.instance.currentUser!;

  Stream<DocumentSnapshot>? _gameStream;

  final _myNumberController = TextEditingController();
  final _minController = TextEditingController(text: "1");
  final _maxController = TextEditingController(text: "100");
  final _guessController = TextEditingController();

  bool _isSubmittingNumber = false;
  bool _isSubmittingGuess = false;

  static void _dbg(String message) {
    debugPrint('[NumberGuess] $message');
  }

  @override
  void initState() {
    super.initState();
    GameState.isPlaying = true;
    _gameStream = GameService.gameStream(widget.roomId);
    _dbg('initState: room=${widget.roomId}');
  }

  @override
  void dispose() {
    GameState.isPlaying = false;
    GameService.disposeStream(widget.roomId);
    _myNumberController.dispose();
    _minController.dispose();
    _maxController.dispose();
    _guessController.dispose();
    super.dispose();
  }

  Future<void> _resetGame() async {
    await GameService.resetNumberGuessGame(roomId: widget.roomId);
  }

  Future<void> _confirmReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Reset Game?"),
        content: const Text(
          "This will delete the current game for both players. "
          "You will both need to set your numbers again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Reset", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) await _resetGame();
  }

  Future<void> _submitMyNumber(Map<String, dynamic>? existingGame) async {
    _dbg('_submitMyNumber: START');
    if (_isSubmittingNumber) {
      _dbg('_submitMyNumber: already submitting, skipping');
      return;
    }

    // ✅ FIX: All validation BEFORE setting loading state
    final number = int.tryParse(_myNumberController.text.trim());
    if (number == null) {
      _dbg('_submitMyNumber: invalid number input');
      _showSnack("Please enter your secret number", Colors.red);
      return;
    }

    final min = int.tryParse(_minController.text.trim()) ?? 1;
    final max = int.tryParse(_maxController.text.trim()) ?? 100;

    if (min >= max) {
      _dbg('_submitMyNumber: min >= max');
      _showSnack("Min must be less than Max", Colors.red);
      return;
    }

    if (number < min || number > max) {
      _dbg('_submitMyNumber: number out of range');
      _showSnack("Number must be between $min and $max", Colors.red);
      return;
    }

    setState(() => _isSubmittingNumber = true);
    _dbg('_submitMyNumber: submitting number=$number, range=$min-$max');

    try {
      // ✅ FIX: Always fetch fresh data from Firestore instead of relying
      // on the stream snapshot which may be stale during a race condition
      // where both players tap "Lock In" at nearly the same time.
      final freshDoc = await FirebaseFirestore.instance
          .collection("chat_rooms")
          .doc(widget.roomId)
          .get();

      final freshData = freshDoc.data();
      final freshGame = freshData?["game"] as Map<String, dynamic>?;

      // ✅ FIX: Check if I've already submitted
      final submitted = freshGame != null
          ? List<String>.from(freshGame["submitted"] ?? [])
          : <String>[];

      if (submitted.contains(currentUser.uid)) {
        _showSnack("You've already locked in your number!", Colors.orange);
        return;
      }

      // ✅ FIX: Determine role more carefully
      final numberSetter = freshGame?["numberSetter"] as String?;
      final guesser = freshGame?["guesser"] as String?;

      // Case 1: No game exists yet → I'm the first player (numberSetter)
      if (freshGame == null) {
        _dbg('_submitMyNumber: no existing game — starting as numberSetter');
        await GameService.startNumberGuessGame(
          roomId: widget.roomId,
          currentUserId: currentUser.uid,
          opponentId: widget.opponentId,
          number: number,
          min: min,
          max: max,
        );
      }
      // Case 2: Game exists and I'm the numberSetter → shouldn't happen, but handle it
      else if (numberSetter == currentUser.uid) {
        _dbg('_submitMyNumber: already the numberSetter');
        _showSnack("You've already set up the game!", Colors.orange);
        return;
      }
      // Case 3: Game exists and I'm the guesser → join the game
      else if (guesser == currentUser.uid) {
        _dbg('_submitMyNumber: joining as guesser');
        await GameService.joinNumberGuessGame(
          roomId: widget.roomId,
          currentUserId: currentUser.uid,
          number: number,
          min: min,
          max: max,
        );
      }
      // Case 4: Game exists but roles are unclear → shouldn't happen
      else {
        _dbg(
          '_submitMyNumber: unclear role, numberSetter=$numberSetter, guesser=$guesser',
        );
        _showSnack(
          "Unable to determine your role. Please reset and try again.",
          Colors.red,
        );
        return;
      }

      _myNumberController.clear();
      _showSnack("Number locked in!", Colors.green);
      _dbg('_submitMyNumber: SUCCESS');
    } catch (e) {
      debugPrint('[NumberGuess] _submitMyNumber: ERROR ${e.runtimeType}');
      // ✅ Better error message
      if (e.toString().contains("missing participants")) {
        _showSnack(
          "Game setup error. Please wait a moment and try again.",
          Colors.orange,
        );
      } else if (e.toString().contains("not a participant")) {
        _showSnack("You are not part of this game.", Colors.red);
      } else {
        _showSnack("Error: ${e.toString()}", Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isSubmittingNumber = false);
    }
  }

  Future<void> _submitGuess(Map<String, dynamic> gameData) async {
    _dbg('_submitGuess: START');
    if (_isSubmittingGuess) {
      _dbg('_submitGuess: already submitting, skipping');
      return;
    }

    final numberSetter =
        gameData["numberSetter"] as String? ?? widget.opponentId;
    final opponentUid = currentUser.uid == numberSetter
        ? (gameData["guesser"] as String? ?? widget.opponentId)
        : numberSetter;

    final min =
        (gameData["min_$opponentUid"] as int?) ??
        (gameData["min"] as int? ?? 1);
    final max =
        (gameData["max_$opponentUid"] as int?) ??
        (gameData["max"] as int? ?? 100);

    final guess = int.tryParse(_guessController.text.trim());

    if (guess == null || guess < min || guess > max) {
      _showSnack("Enter a valid number between $min and $max", Colors.red);
      return;
    }

    setState(() => _isSubmittingGuess = true);
    _guessController.clear();

    try {
      await GameService.makeNumberGuess(
        roomId: widget.roomId,
        guess: guess,
        currentUserId: currentUser.uid,
      );
    } catch (e) {
      _showSnack("Failed to submit. Try again.", Colors.red);
    } finally {
      if (mounted) setState(() => _isSubmittingGuess = false);
    }
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
              "🔢 Number Guess",
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
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: colors.primaryText),
            tooltip: "Reset Game",
            onPressed: _confirmReset,
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _gameStream ?? const Stream.empty(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(color: colors.accent),
            );
          }

          final roomData = snapshot.data!.data() as Map<String, dynamic>?;
          final gameData = roomData?["game"] as Map<String, dynamic>?;

          if (gameData == null) {
            return _buildSetupScreen(colors, null);
          }

          final status = gameData["status"] as String? ?? "waiting";
          final submitted = List<String>.from(gameData["submitted"] ?? []);
          final iHaveSubmitted = submitted.contains(currentUser.uid);

          if (!iHaveSubmitted) {
            return _buildSetupScreen(colors, gameData);
          }

          if (status == "waiting") {
            return _buildWaitingForOpponent(gameData, colors);
          }

          if (status == "finished" || status == "draw") {
            return _buildGameOver(gameData, colors);
          }

          final guessTurn = gameData["guessTurn"] as String?;
          final isMyTurn = guessTurn == currentUser.uid;

          return _buildActiveGame(gameData, isMyTurn, colors);
        },
      ),
    );
  }

  Widget _buildSetupScreen(AppColors colors, Map<String, dynamic>? gameData) {
    final isSecondPlayer = gameData != null;
    final opponentMin = gameData?["min"] as int?;
    final opponentMax = gameData?["max"] as int?;

    return SingleChildScrollView(
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(20),
          color: colors.cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_outline,
                    size: 40,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "Set Your Secret Number",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: colors.primaryText,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "${widget.opponentName} will guess your number.\n"
                  "You will guess their number!",
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                  textAlign: TextAlign.center,
                ),

                if (isSecondPlayer &&
                    opponentMin != null &&
                    opponentMax != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: Colors.orange,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            "${widget.opponentName} set range: $opponentMin – $opponentMax\n"
                            "You can use the same or pick your own!",
                            style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (isSecondPlayer) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.blue.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.hourglass_bottom,
                          color: Colors.blue,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            "Waiting for ${widget.opponentName}'s range...",
                            style: const TextStyle(
                              color: Colors.blue,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                Text(
                  "Your range:",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.primaryText,
                  ),
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  controller: _minController,
                  label: "Min",
                  icon: Icons.arrow_downward,
                  color: Colors.blue,
                  colors: colors,
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  controller: _maxController,
                  label: "Max",
                  icon: Icons.arrow_upward,
                  color: Colors.green,
                  colors: colors,
                ),

                const SizedBox(height: 12),
                _buildTextField(
                  controller: _myNumberController,
                  label: "Your Secret Number",
                  icon: Icons.lock,
                  color: const Color(0xFF8B5CF6),
                  colors: colors,
                ),
                const SizedBox(height: 28),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isSubmittingNumber
                        ? null
                        : () => _submitMyNumber(gameData),
                    icon: _isSubmittingNumber
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.lock),
                    label: const Text(
                      "Lock In My Number",
                      style: TextStyle(fontSize: 16),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingForOpponent(
    Map<String, dynamic> gameData,
    AppColors colors,
  ) {
    final myNumber = gameData["number_${currentUser.uid}"];

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: colors.accent),
            const SizedBox(height: 24),
            Text(
              "Your number is locked in! 🔒",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.primaryText,
              ),
            ),
            const SizedBox(height: 16),
            _buildMySecretBadge(myNumber, colors),
            const SizedBox(height: 16),
            Text(
              "Waiting for ${widget.opponentName} to set their number...\n"
              "They will guess first when they join!",
              style: TextStyle(fontSize: 14, color: colors.secondaryText),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _confirmReset,
                icon: Icon(Icons.refresh, color: colors.secondaryText),
                label: Text(
                  "Reset Game",
                  style: TextStyle(color: colors.secondaryText),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colors.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveGame(
    Map<String, dynamic> gameData,
    bool isMyTurn,
    AppColors colors,
  ) {
    final numberSetter2 =
        gameData["numberSetter"] as String? ?? widget.opponentId;
    final opponentUidForRange = currentUser.uid == numberSetter2
        ? (gameData["guesser"] as String? ?? widget.opponentId)
        : numberSetter2;

    final min =
        (gameData["min_$opponentUidForRange"] as int?) ??
        (gameData["min"] as int? ?? 1);
    final max =
        (gameData["max_$opponentUidForRange"] as int?) ??
        (gameData["max"] as int? ?? 100);
    final myHint = gameData["hint_${currentUser.uid}"] as String?;
    final myLastGuess = gameData["lastGuess_${currentUser.uid}"];
    final myGuessCount =
        (gameData["guessCount_${currentUser.uid}"] as int?) ?? 0;
    final iWon = gameData["winner"] == currentUser.uid;

    final numberSetter =
        gameData["numberSetter"] as String? ?? widget.opponentId;
    final guesser = gameData["guesser"] as String? ?? widget.opponentId;
    final opponentUid = currentUser.uid == numberSetter
        ? guesser
        : numberSetter;

    final opponentLastGuess = gameData["lastGuess_$opponentUid"];
    final opponentHint = gameData["hint_$opponentUid"] as String?;
    final opponentGuessCount =
        ((gameData["guessCount_$opponentUid"] as int?) ?? 0);
    final opponentWon = gameData["winner"] == opponentUid;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SizedBox(height: 12),
          _buildTurnIndicator(isMyTurn, colors),
          const SizedBox(height: 16),

          _buildTrackCard(
            title: "🎯 You Guessing ${widget.opponentName}'s Number",
            color: const Color(0xFF3B82F6),
            colors: colors,
            child: iWon
                ? _buildTrackWon(myGuessCount, colors)
                : isMyTurn
                ? _buildMyGuessInput(
                    min,
                    max,
                    myLastGuess,
                    myHint,
                    myGuessCount,
                    colors,
                    gameData,
                  )
                : _buildWaitingForMyTurn(
                    myLastGuess,
                    myHint,
                    myGuessCount,
                    colors,
                  ),
          ),

          const SizedBox(height: 16),

          _buildTrackCard(
            title: "💡 ${widget.opponentName} Guessing Your Number",
            color: const Color(0xFF8B5CF6),
            colors: colors,
            child: opponentWon
                ? _buildOpponentTrackWon(opponentGuessCount, colors)
                : _buildOpponentStatus(
                    opponentLastGuess,
                    opponentHint,
                    opponentGuessCount,
                    isMyTurn,
                    colors,
                  ),
          ),

          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _confirmReset,
              icon: Icon(Icons.refresh, color: colors.secondaryText),
              label: Text(
                "Reset Game",
                style: TextStyle(color: colors.secondaryText),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: colors.borderColor),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildGameOver(Map<String, dynamic> gameData, AppColors colors) {
    final winner = gameData["winner"] as String?;
    final status = gameData["status"] as String? ?? "finished";
    final isDraw = status == "draw" && winner == null;
    final isWinner = winner == currentUser.uid;

    final myGuessCount =
        (gameData["guessCount_${currentUser.uid}"] as int?) ?? 0;
    final numberSetter =
        gameData["numberSetter"] as String? ?? widget.opponentId;
    final guesser = gameData["guesser"] as String? ?? widget.opponentId;
    final opponentUid = currentUser.uid == numberSetter
        ? guesser
        : numberSetter;
    final opponentGuessCount =
        ((gameData["guessCount_$opponentUid"] as int?) ?? 0);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: isDraw
                    ? Colors.blue.withValues(alpha: 0.1)
                    : isWinner
                    ? Colors.amber.withValues(alpha: 0.1)
                    : Colors.grey.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isDraw
                    ? Icons.handshake_outlined
                    : isWinner
                    ? Icons.emoji_events
                    : Icons.sentiment_dissatisfied,
                size: 70,
                color: isDraw
                    ? Colors.blue
                    : isWinner
                    ? Colors.amber
                    : Colors.grey,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isDraw
                  ? "It's a Draw! 🤝"
                  : isWinner
                  ? "You Won! 🎉"
                  : "${widget.opponentName} Won! 😢",
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: colors.primaryText,
              ),
            ),
            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.borderColor),
              ),
              child: Column(
                children: [
                  Text(
                    "Game Summary",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colors.primaryText,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildStatRow(
                    "Your guesses",
                    "$myGuessCount",
                    Colors.green,
                    colors,
                  ),
                  const SizedBox(height: 6),
                  _buildStatRow(
                    "${widget.opponentName}'s guesses",
                    "$opponentGuessCount",
                    Colors.orange,
                    colors,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _resetGame,
                icon: const Icon(Icons.refresh),
                label: const Text("Play Again"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8B5CF6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: Icon(
                  Icons.grid_view_rounded,
                  color: colors.secondaryText,
                ),
                label: Text(
                  "Back to Games",
                  style: TextStyle(color: colors.secondaryText),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colors.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMySecretBadge(dynamic myNumber, AppColors colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8B5CF6).withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, color: Colors.white70, size: 20),
          const SizedBox(width: 10),
          Text(
            "Secret is locked:",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            "✓",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurnIndicator(bool isMyTurn, AppColors colors) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isMyTurn
            ? Colors.green.withValues(alpha: 0.1)
            : Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isMyTurn
              ? Colors.green.withValues(alpha: 0.4)
              : Colors.orange.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isMyTurn ? Icons.play_circle_outline : Icons.hourglass_top,
            color: isMyTurn ? Colors.green : Colors.orange,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            isMyTurn
                ? "🟢 Your turn to guess!"
                : "🟠 ${widget.opponentName}'s turn...",
            style: TextStyle(
              color: isMyTurn ? Colors.green.shade700 : Colors.orange.shade700,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackCard({
    required String title,
    required Color color,
    required AppColors colors,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }

  Widget _buildMyGuessInput(
    int min,
    int max,
    dynamic lastGuess,
    String? hint,
    int guessCount,
    AppColors colors,
    Map<String, dynamic> gameData,
  ) {
    Color hintColor = colors.secondaryText;
    IconData hintIcon = Icons.help_outline;

    if (hint != null) {
      if (hint.contains("Higher")) {
        hintColor = Colors.green.shade700;
        hintIcon = Icons.arrow_upward;
      } else if (hint.contains("Lower")) {
        hintColor = Colors.red.shade700;
        hintIcon = Icons.arrow_downward;
      } else {
        hintColor = const Color(0xFF8B5CF6);
        hintIcon = Icons.check_circle_outline;
      }
    }

    return Column(
      children: [
        if (guessCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.format_list_numbered,
                  size: 14,
                  color: colors.secondaryText,
                ),
                const SizedBox(width: 4),
                Text(
                  "Guesses so far: $guessCount",
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
              ],
            ),
          ),

        if (hint != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: hintColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hintColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(hintIcon, color: hintColor, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    hint,
                    style: TextStyle(
                      color: hintColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),

        TextField(
          controller: _guessController,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: colors.primaryText,
          ),
          decoration: InputDecoration(
            labelText: hint == null
                ? "Make your first guess! ($min – $max)"
                : "Your next guess ($min – $max)",
            labelStyle: TextStyle(color: colors.secondaryText),
            prefixIcon: const Icon(
              Icons.casino_outlined,
              color: Color(0xFF3B82F6),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2),
            ),
          ),
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isSubmittingGuess ? null : () => _submitGuess(gameData),
            icon: _isSubmittingGuess
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send),
            label: Text(
              lastGuess == null ? "Submit First Guess" : "Submit Guess",
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B82F6),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWaitingForMyTurn(
    dynamic lastGuess,
    String? hint,
    int guessCount,
    AppColors colors,
  ) {
    Color hintColor = colors.secondaryText;
    IconData hintIcon = Icons.help_outline;

    if (hint != null) {
      if (hint.contains("Higher")) {
        hintColor = Colors.green.shade700;
        hintIcon = Icons.arrow_upward;
      } else if (hint.contains("Lower")) {
        hintColor = Colors.red.shade700;
        hintIcon = Icons.arrow_downward;
      }
    }

    return Column(
      children: [
        if (guessCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.format_list_numbered,
                  size: 14,
                  color: colors.secondaryText,
                ),
                const SizedBox(width: 4),
                Text(
                  "Guesses so far: $guessCount",
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
                ),
              ],
            ),
          ),

        if (hint != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: hintColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hintColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(hintIcon, color: hintColor, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    hint,
                    style: TextStyle(
                      color: hintColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),

        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.orange,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                "Wait for opponent's turn...",
                style: TextStyle(fontSize: 14, color: colors.secondaryText),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOpponentStatus(
    dynamic opponentLastGuess,
    String? opponentHint,
    int opponentGuessCount,
    bool isMyTurn,
    AppColors colors,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.secondaryText.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          if (opponentGuessCount > 0) ...[
            Text(
              "Guesses made: $opponentGuessCount",
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
            const SizedBox(height: 6),
            if (opponentLastGuess != null)
              Text(
                "Last guess: $opponentLastGuess",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.primaryText,
                ),
              ),
            if (opponentHint != null) ...[
              const SizedBox(height: 4),
              Text(
                "Hint: $opponentHint",
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            ],
            const SizedBox(height: 10),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isMyTurn) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  isMyTurn
                      ? "${widget.opponentName} is waiting for your guess..."
                      : opponentLastGuess == null
                      ? "${widget.opponentName} is making their first guess..."
                      : "${widget.opponentName} is guessing...",
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrackWon(int guessCount, AppColors colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 22),
              SizedBox(width: 8),
              Text(
                "You guessed it! 🎉",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Solved in $guessCount guess${guessCount == 1 ? '' : 'es'}",
            style: TextStyle(fontSize: 12, color: Colors.green.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildOpponentTrackWon(int guessCount, AppColors colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, color: Colors.orange, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  "${widget.opponentName} guessed your number!",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "They solved it in $guessCount guess${guessCount == 1 ? '' : 'es'}",
            style: TextStyle(fontSize: 12, color: Colors.orange.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(
    String label,
    String value,
    Color color,
    AppColors colors,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 13, color: colors.secondaryText),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required Color color,
    required AppColors colors,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: TextInputType.number,
      style: TextStyle(color: colors.primaryText),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: colors.secondaryText),
        prefixIcon: Icon(icon, color: color, size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: 2),
        ),
      ),
    );
  }

  void _showSnack(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
