class GameState {
  static int _activeCount = 0;

  static bool get isPlaying => _activeCount > 0;

  static void enter() => _activeCount++;

  static void leave() {
    if (_activeCount > 0) _activeCount--;
  }
}
