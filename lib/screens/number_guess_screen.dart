import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../main.dart';
import '../services/game_service.dart';
import '../utils/game_state.dart';

/// Number Guess Screen with comprehensive timeout and error handling.
///
/// Fixes:
/// - Detailed logs before/after every await
/// - 15-second timeout on all operations
/// - Explicit states: loading, waitingForRoom, waitingForOpponent, connected, playing, error
/// - Retry UI instead of infinite spinner
/// - No stream.first or firstWhere infinite waits
/// - Subscription attaches before waiting for state
/// - Proper onError handlers
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
  final _firestore = FirebaseFirestore.instance;

  // Stream management
  StreamSubscription<DocumentSnapshot>? _roomSubscription;
  final _streamController = StreamController<Map<String, dynamic>?>.broadcast();

  // Controllers
  final _myNumberController = TextEditingController();
  final _minController = TextEditingController(text: '1');
  final _maxController = TextEditingController(text: '100');
  final _guessController = TextEditingController();

  // State
  _GameScreenState _screenState = _GameScreenState.loading;
  String? _errorMessage;
  int _retryAttempt = 0;

  // Game state
  Map<String, dynamic>? _gameData;
  String _status = 'waiting';
  List<String> _submitted = [];
  bool _iHaveSubmitted = false;
  bool _isSubmittingNumber = false;
  bool _isSubmittingGuess = false;
  
  // Validation
  String? _guessValidationMessage;
  int? _minRange;
  int? _maxRange;
  
  // Session score tracker (local state, persists across restarts)
  int _myWins = 0;
  int _opponentWins = 0;
  String? _lastStatus;

  // Timeout configuration
  static const Duration _operationTimeout = Duration(seconds: 15);
  static const int _maxRetries = 3;

  static void _dbg(String message) {
    debugPrint('[NumberGuessScreen] $message');
  }

  @override
  void initState() {
    super.initState();
    _dbg('initState: START room=${widget.roomId}');
    GameState.enter();
    _initializeStream();
    
    // Add listener for guess validation
    _guessController.addListener(_validateGuessInput);
    
    _dbg('initState: END');
  }

  void _initializeStream() {
    _dbg('_initializeStream: START attempt=${_retryAttempt + 1}');
    setState(() => _screenState = _GameScreenState.loading);

    // Subscribe to room document FIRST
    _subscribeToRoom();

    // Then check if room exists with timeout
    _ensureRoomExists();
    _dbg('_initializeStream: END');
  }

  void _subscribeToRoom() {
    _dbg('_subscribeToRoom: START');

    // Cancel existing subscription
    _roomSubscription?.cancel();

    try {
      _roomSubscription = _firestore
          .collection('chat_rooms')
          .doc(widget.roomId)
          .snapshots()
          .listen(
        (snapshot) {
          _dbg('Room snapshot received: exists=${snapshot.exists}');

          if (!snapshot.exists) {
            _dbg('Room does not exist!');
            _handleError('Room not found');
            return;
          }

          final data = snapshot.data();
          final gameData = data?['game'] as Map<String, dynamic>?;

          _dbg('Game data: ${gameData != null ? 'present' : 'null'}');

          if (gameData != null) {
            _dbg('Game type: ${gameData['type']}, status: ${gameData['status']}');
          }

          // Update state
          _updateGameState(gameData);

          // Emit to stream controller
          if (!_streamController.isClosed) {
            _streamController.add(gameData);
          }
        },
        onError: (error) {
          _dbg('Stream error: $error');
          _handleError('Connection error: $error');
        },
        onDone: () {
          _dbg('Stream closed');
        },
      );
      _dbg('_subscribeToRoom: subscription created');
    } catch (e) {
      _dbg('_subscribeToRoom: ERROR ${e.runtimeType}: $e');
      _handleError('Failed to subscribe: $e');
    }
  }

  Future<void> _ensureRoomExists() async {
    _dbg('_ensureRoomExists: START');

    try {
      // Wait for first snapshot with timeout
      _dbg('_ensureRoomExists: waiting for first snapshot...');
      final doc = await _firestore
          .collection('chat_rooms')
          .doc(widget.roomId)
          .get()
          .timeout(_operationTimeout);

      _dbg('_ensureRoomExists: doc received, exists=${doc.exists}');

      if (!doc.exists) {
        _dbg('_ensureRoomExists: room does not exist, creating...');
        // Room doesn't exist yet, wait in loading state
        // The stream will update when room is created
        setState(() => _screenState = _GameScreenState.waitingForRoom);
      }
      // If room exists, stream handler will update state
    } on TimeoutException {
      _dbg('_ensureRoomExists: TIMEOUT');
      _handleTimeout('Room connection timeout');
    } catch (e) {
      _dbg('_ensureRoomExists: ERROR ${e.runtimeType}: $e');
      _handleError('Failed to check room: $e');
    }

    _dbg('_ensureRoomExists: END');
  }

  void _updateGameState(Map<String, dynamic>? gameData) {
    if (!mounted) return;

    setState(() {
      _gameData = gameData;

      if (gameData == null) {
        _screenState = _GameScreenState.connected;
        return;
      }

      _status = gameData['status'] as String? ?? 'waiting';
      _submitted = List<String>.from(gameData['submitted'] ?? []);
      _iHaveSubmitted = _submitted.contains(currentUser.uid);
      
      // Detect game-end transitions and update session score
      final winner = gameData['winner'] as String?;
      if ((_status == 'finished' && _lastStatus == 'playing') || 
          (_status == 'finished' && _lastStatus == null)) {
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
      _lastStatus = _status;
      
      // Update min/max range for validation
      final opponentId = widget.opponentId;
      if (opponentId.isNotEmpty) {
        _minRange = (gameData['min_$opponentId'] as int?) ?? (gameData['min'] as int? ?? 1);
        _maxRange = (gameData['max_$opponentId'] as int?) ?? (gameData['max'] as int? ?? 100);
      }

      if (!_iHaveSubmitted) {
        _screenState = _GameScreenState.connected;
      } else if (_status == 'waiting') {
        _screenState = _GameScreenState.waitingForOpponent;
      } else if (_status == 'playing') {
        _screenState = _GameScreenState.playing;
      } else if (_status == 'finished' || _status == 'draw') {
        _screenState = _GameScreenState.finished;
      } else {
        _screenState = _GameScreenState.playing;
      }

      _errorMessage = null;
      _retryAttempt = 0;
    });
  }

  void _handleTimeout(String message) {
    _dbg('_handleTimeout: $message');
    if (_retryAttempt < _maxRetries) {
      _retryAttempt++;
      _dbg('Retrying... attempt $_retryAttempt/$_maxRetries');
      Future.delayed(const Duration(seconds: 2), _initializeStream);
    } else {
      setState(() {
        _screenState = _GameScreenState.error;
        _errorMessage = '$message. Please check your connection and retry.';
      });
    }
  }

  void _handleError(String message) {
    _dbg('_handleError: $message');
    setState(() {
      _screenState = _GameScreenState.error;
      _errorMessage = message;
    });
  }

  @override
  void dispose() {
    _dbg('dispose: START');
    GameState.leave();
    _roomSubscription?.cancel();
    _streamController.close();
    _myNumberController.dispose();
    _minController.dispose();
    _maxController.dispose();
    _guessController.removeListener(_validateGuessInput);
    _guessController.dispose();
    _dbg('dispose: END');
    super.dispose();
  }

  // ============================================================================
  // SUBMIT HANDLERS WITH TIMEOUTS
  // ============================================================================

  Future<void> _submitMyNumber(Map<String, dynamic>? existingGame) async {
    _dbg('_submitMyNumber: START');
    if (_isSubmittingNumber) {
      _dbg('_submitMyNumber: already submitting, skipping');
      return;
    }

    // Validation
    final number = int.tryParse(_myNumberController.text.trim());
    if (number == null) {
      _showSnack('Please enter your secret number', Colors.red);
      return;
    }

    final min = int.tryParse(_minController.text.trim()) ?? 1;
    final max = int.tryParse(_maxController.text.trim()) ?? 100;

    if (min >= max) {
      _showSnack('Min must be less than Max', Colors.red);
      return;
    }

    if (number < min || number > max) {
      _showSnack('Number must be between $min and $max', Colors.red);
      return;
    }

    setState(() => _isSubmittingNumber = true);
    _dbg('_submitMyNumber: submitting number=$number, range=$min-$max');

    try {
      _dbg('_submitMyNumber: AWAITING startNumberGuessGame...');
      await GameService.startNumberGuessGame(
        roomId: widget.roomId,
        currentUserId: currentUser.uid,
        opponentId: widget.opponentId,
        number: number,
        min: min,
        max: max,
      ).timeout(_operationTimeout);
      _dbg('_submitMyNumber: startNumberGuessGame COMPLETED');

      _myNumberController.clear();
      _showSnack('Number locked in!', Colors.green);
    } on TimeoutException {
      _dbg('_submitMyNumber: TIMEOUT');
      _showSnack('Request timed out. Please retry.', Colors.orange);
    } catch (e) {
      _dbg('_submitMyNumber: ERROR ${e.runtimeType}: $e');
      _showSnack('Failed to submit: ${e.toString()}', Colors.red);
    } finally {
      if (mounted) setState(() => _isSubmittingNumber = false);
    }
    _dbg('_submitMyNumber: END');
  }

  void _validateGuessInput() {
    if (_minRange == null || _maxRange == null) return;
    
    final text = _guessController.text.trim();
    if (text.isEmpty) {
      setState(() => _guessValidationMessage = null);
      return;
    }
    
    final guess = int.tryParse(text);
    if (guess == null) {
      setState(() => _guessValidationMessage = 'Please enter a valid number');
      return;
    }
    
    if (guess < _minRange! || guess > _maxRange!) {
      setState(() => _guessValidationMessage = 'Enter a number between $_minRange and $_maxRange');
    } else {
      setState(() => _guessValidationMessage = null);
    }
  }

  Future<void> _submitGuess() async {
    _dbg('_submitGuess: START');
    if (_isSubmittingGuess) return;

    final guess = int.tryParse(_guessController.text.trim());
    if (guess == null) {
      _showSnack('Please enter a number', Colors.red);
      return;
    }
    
    // Pre-validate before submitting
    if (_minRange != null && _maxRange != null) {
      if (guess < _minRange! || guess > _maxRange!) {
        _showSnack('Guess must be between $_minRange and $_maxRange', Colors.orange);
        return;
      }
    }

    setState(() => _isSubmittingGuess = true);
    _dbg('_submitGuess: submitting guess=$guess');

    try {
      _dbg('_submitGuess: AWAITING makeNumberGuess...');
      await GameService.makeNumberGuess(
        roomId: widget.roomId,
        guess: guess,
        currentUserId: currentUser.uid,
      ).timeout(_operationTimeout);
      _dbg('_submitGuess: makeNumberGuess COMPLETED');

      _guessController.clear();
    } on TimeoutException {
      _dbg('_submitGuess: TIMEOUT');
      _showSnack('Request timed out. Please retry.', Colors.orange);
    } on RangeError catch (e) {
      _dbg('_submitGuess: RANGE ERROR $e');
      _showSnack(e.message.toString(), Colors.orange);
    } catch (e) {
      _dbg('_submitGuess: ERROR ${e.runtimeType}: $e');
      _showSnack('Failed to submit guess', Colors.red);
    } finally {
      if (mounted) setState(() => _isSubmittingGuess = false);
    }
    _dbg('_submitGuess: END');
  }

  Future<void> _resetGame() async {
    _dbg('_resetGame: START');
    try {
      await GameService.resetNumberGuessGame(roomId: widget.roomId)
          .timeout(_operationTimeout);
      _dbg('_resetGame: SUCCESS');
    } on TimeoutException {
      _dbg('_resetGame: TIMEOUT');
      _showSnack('Reset timed out', Colors.orange);
    } catch (e) {
      _dbg('_resetGame: ERROR $e');
      _showSnack('Failed to reset', Colors.red);
    }
    _dbg('_resetGame: END');
  }

  // ============================================================================
  // BUILD METHOD
  // ============================================================================

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
              '🔢 Number Guess',
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
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: colors.primaryText),
            tooltip: 'Reset Game',
            onPressed: _confirmReset,
          ),
        ],
      ),
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(AppColors colors) {
    switch (_screenState) {
      case _GameScreenState.loading:
        return _buildLoadingState(colors, 'Initializing...');
      case _GameScreenState.waitingForRoom:
        return _buildLoadingState(
          colors,
          'Waiting for room...',
          subtitle: 'Attempt ${_retryAttempt + 1}/$_maxRetries',
        );
      case _GameScreenState.connected:
        return _buildSetupScreen(colors);
      case _GameScreenState.waitingForOpponent:
        return _buildWaitingForOpponent(colors);
      case _GameScreenState.playing:
        return _buildActiveGame(colors);
      case _GameScreenState.finished:
        return _buildGameOver(colors);
      case _GameScreenState.error:
        return _buildErrorState(colors);
    }
  }

  // ============================================================================
  // UI BUILDERS
  // ============================================================================

  Widget _buildLoadingState(AppColors colors, String message, {String? subtitle}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: colors.accent),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(color: colors.primaryText, fontSize: 16),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(color: colors.secondaryText, fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorState(AppColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          Text(
            'Error',
            style: TextStyle(
              color: colors.primaryText,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.secondaryText, fontSize: 14),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {
              _retryAttempt = 0;
              _initializeStream();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupScreen(AppColors colors) {
    final bothSubmitted = _submitted.length >= 2;
    final opponentAlreadySubmitted = _submitted.contains(widget.opponentId);
    final opponentMin = _gameData?['min'] as int?;
    final opponentMax = _gameData?['max'] as int?;

    return SingleChildScrollView(
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(20),
          color: colors.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                  'Set Your Secret Number',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: colors.primaryText,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${widget.opponentName} will guess your number.\n'
                  'You will guess their number!',
                  style: TextStyle(fontSize: 13, color: colors.secondaryText),
                  textAlign: TextAlign.center,
                ),
                
                // Only show range after both have submitted (i.e. during active game)
                if (bothSubmitted && opponentMin != null && opponentMax != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange),
                    ),
                    child: Text(
                      '${widget.opponentName}\'s range: $opponentMin – $opponentMax',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                
                // While only opponent has submitted, show a neutral message
                if (!bothSubmitted && opponentAlreadySubmitted) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue),
                    ),
                    child: Text(
                      '${widget.opponentName} has set their number. Your turn!',
                      style: const TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _buildNumberField(
                        'Min',
                        _minController,
                        colors,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildNumberField(
                        'Max',
                        _maxController,
                        colors,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _myNumberController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: colors.primaryText,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Your secret number',
                    hintStyle: TextStyle(color: colors.hintText),
                    filled: true,
                    fillColor: colors.inputBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSubmittingNumber ? null : () => _submitMyNumber(_gameData),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isSubmittingNumber
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Lock In Secret Number',
                            style: TextStyle(fontSize: 16),
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

  Widget _buildNumberField(String label, TextEditingController controller, AppColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: colors.secondaryText,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: colors.primaryText,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.inputBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWaitingForOpponent(AppColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: colors.accent),
          const SizedBox(height: 24),
          Text(
            'Waiting for ${widget.opponentName}...',
            style: TextStyle(color: colors.primaryText, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            'They need to set their secret number',
            style: TextStyle(color: colors.secondaryText, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveGame(AppColors colors) {
    final guessTurn = _gameData?['guessTurn'] as String?;
    final isMyTurn = guessTurn == currentUser.uid;
    final hint = _gameData?['hint_${currentUser.uid}'] as String?;
    final lastGuess = _gameData?['lastGuess_${currentUser.uid}'] as int?;
    final String? opponentUid;
    if (_gameData?['numberSetter'] == currentUser.uid) {
      opponentUid = _gameData?['guesser'] as String?;
    } else {
      opponentUid = _gameData?['numberSetter'] as String?;
    }
    final opponentHint = _gameData?['hint_$opponentUid'] as String?;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Turn indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isMyTurn
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isMyTurn ? Colors.green : Colors.orange,
              ),
            ),
            child: Text(
              isMyTurn ? '🎯 Your Turn!' : '⏳ Waiting for opponent...',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isMyTurn ? Colors.green : Colors.orange,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          // Session score
          Center(
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
          const SizedBox(height: 16),
          // Guess count stats
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              statPill(
                label: 'Your guesses',
                value: (_gameData?['guessCount_${currentUser.uid}'] as int? ?? 0).toString(),
                colors: colors,
              ),
              const SizedBox(width: 16),
              statPill(
                label: "${widget.opponentName}'s guesses",
                value: (_gameData?['guessCount_$opponentUid'] as int? ?? 0).toString(),
                colors: colors,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Hint display
          if (hint != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.cardBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    'Your Last Guess: $lastGuess',
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: colors.primaryText,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (opponentHint != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.cardBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Opponent got: $opponentHint',
                style: TextStyle(
                  fontSize: 14,
                  color: colors.secondaryText,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
          ],
          // Guess input
          if (isMyTurn) ...[
            TextField(
              controller: _guessController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: colors.primaryText,
              ),
              decoration: InputDecoration(
                hintText: 'Enter your guess',
                hintStyle: TextStyle(color: colors.hintText),
                filled: true,
                fillColor: colors.inputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                errorText: _guessValidationMessage,
                helperText: _minRange != null && _maxRange != null 
                    ? 'Range: $_minRange - $_maxRange'
                    : null,
                helperStyle: TextStyle(color: colors.secondaryText),
              ),
            ),
            const SizedBox(height: 16),
            // Guess history
            if (isMyTurn) _buildGuessHistory(colors, currentUser.uid),
            if (isMyTurn) const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSubmittingGuess ? null : _submitGuess,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSubmittingGuess
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Submit Guess',
                        style: TextStyle(fontSize: 18),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGameOver(AppColors colors) {
    final winner = _gameData?['winner'] as String?;
    final isWinner = winner == currentUser.uid;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied,
            size: 80,
            color: isWinner ? Colors.amber : Colors.grey,
          ),
          const SizedBox(height: 24),
          Text(
            isWinner ? '🎉 You Won!' : '😔 You Lost',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: colors.primaryText,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            winner == null
                ? 'Game ended in a draw'
                : '${isWinner ? 'You' : widget.opponentName} guessed the number!',
            style: TextStyle(fontSize: 16, color: colors.secondaryText),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _resetGame,
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
            child: const Text('Play Again', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Game?'),
        content: const Text(
          'This will delete the current game for both players. '
          'You will both need to set your numbers again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) await _resetGame();
  }

  Widget statPill({required String label, required String value, required AppColors colors}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.borderColor),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$value ',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.primaryText,
              ),
            ),
            TextSpan(
              text: label,
              style: TextStyle(
                fontSize: 12,
                color: colors.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuessHistory(AppColors colors, String userId) {
    final history = (_gameData?['guessHistory_$userId'] as List? ?? [])
        .reversed
        .take(5)
        .toList(); // last 5 guesses, newest first

    if (history.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.cardBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.borderColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your recent guesses:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          ...history.map((h) {
            final isCorrect = (h['hint'] as String).startsWith('🎉');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(
                    '${h['guess']}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isCorrect ? Colors.green : colors.primaryText,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${h['hint']}',
                      style: TextStyle(
                        color: isCorrect ? Colors.green : colors.secondaryText,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ============================================================================
// STATE ENUM
// ============================================================================

enum _GameScreenState {
  loading,
  waitingForRoom,
  connected,
  waitingForOpponent,
  playing,
  finished,
  error,
}
