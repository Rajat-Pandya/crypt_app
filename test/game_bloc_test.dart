import 'package:flutter_test/flutter_test.dart';

import 'package:crypt_app/blocs/game_bloc.dart';

void main() {
  group('GameBloc', () {
    late GameBloc gameBloc;
    const roomId = 'room_123';
    const currentUserId = 'user_456';

    setUp(() {
      gameBloc = GameBloc();
    });

    tearDown(() {
      gameBloc.close();
    });

    test('initial state is correct', () {
      expect(gameBloc.state.isInitialized, isFalse);
      expect(gameBloc.state.isLoading, isFalse);
      expect(gameBloc.state.isGameActive, isFalse);
      expect(gameBloc.state.gameType, isNull);
      expect(gameBloc.state.winnerId, isNull);
      expect(gameBloc.state.isDraw, isFalse);
      expect(gameBloc.state.board, isEmpty);
      expect(gameBloc.state.players, isEmpty);
      expect(gameBloc.state.moveCount, equals(0));
    });

    test('GameInitialized sets isInitialized', () {
      gameBloc.add(const GameInitialized(
        roomId: roomId,
        currentUserId: currentUserId,
      ));
      expect(gameBloc.state.isInitialized, isTrue);
    });

    test('StartGame sets loading', () {
      gameBloc.add(const StartGame('tic_tac_toe'));
      expect(gameBloc.state.isLoading, isTrue);
    });

    test('ToggleGameMode updates isGameActive', () {
      gameBloc.add(const ToggleGameMode(true));
      expect(gameBloc.state.isGameActive, isTrue);
    });

    test('ResetGame clears game state', () {
      gameBloc.add(const ToggleGameMode(true));
      gameBloc.add(const ResetGame());
      expect(gameBloc.state.isGameActive, isFalse);
      expect(gameBloc.state.board, isEmpty);
    });

    test('isGameOver returns true when winner', () {
      gameBloc.add(const GameStateUpdated({
        'type': 'tic_tac_toe',
        'isActive': true,
        'board': ['X', 'X', 'X', null, null, null, null, null, null],
        'winnerId': 'player1',
        'players': [
          {'id': 'player1', 'name': 'Player 1', 'symbol': 'X', 'isOnline': true},
        ],
      }));
      expect(gameBloc.state.isGameOver, isTrue);
    });

    test('isGameOver returns true when draw', () {
      gameBloc.add(const GameStateUpdated({
        'type': 'tic_tac_toe',
        'isActive': true,
        'board': ['X', 'O', 'X', 'X', 'O', 'O', 'O', 'X', 'X'],
        'isDraw': true,
        'players': [],
      }));
      expect(gameBloc.state.isGameOver, isTrue);
    });

    test('isValidMove validates position', () {
      gameBloc.add(const GameStateUpdated({
        'type': 'tic_tac_toe',
        'isActive': true,
        'board': [null, null, null, null, null, null, null, null, null],
        'players': [],
      }));
      expect(gameBloc.state.isValidMove(0), isTrue);
      expect(gameBloc.state.isValidMove(-1), isFalse);
      expect(gameBloc.state.isValidMove(9), isFalse);
    });

    test('availableMoves returns empty positions', () {
      gameBloc.add(const GameStateUpdated({
        'type': 'tic_tac_toe',
        'isActive': true,
        'board': ['X', null, 'O', null, null, null, null, null, null],
        'players': [],
      }));
      expect(gameBloc.state.availableMoves, equals([1, 3, 4, 5, 6, 7, 8]));
    });

    test('GamePlayer creates with defaults', () {
      const player = GamePlayer(
        id: 'p1',
        name: 'Player 1',
        symbol: 'X',
      );
      expect(player.isOnline, isTrue);
    });

    test('GamePlayer copyWith creates modified copy', () {
      const player = GamePlayer(
        id: 'p1',
        name: 'Player 1',
        symbol: 'X',
      );
      final modified = player.copyWith(isOnline: false);
      expect(modified.isOnline, isFalse);
      expect(modified.name, equals('Player 1'));
    });

    test('state copyWith creates modified copy', () {
      final original = gameBloc.state;
      final modified = original.copyWith(
        isGameActive: true,
        moveCount: 5,
      );
      expect(modified.isGameActive, isTrue);
      expect(modified.moveCount, equals(5));
    });
  });
}
