// One thing at a time on the phone's Bluetooth: a scan, a connection, a track pull. Whoever holds the link
// finishes before the next starts, so opening a puck's screen while its tracks are coming over in the
// background waits for them instead of crashing into the same connection.
import 'dart:async';

class PuckLink {
  Completer<void>? _held;

  /// Is something using the link right now?
  bool get isHeld => _held != null;

  /// Wait for the link, then hold it. Call the function this returns (once is enough) to let go.
  Future<void Function()> acquire() async {
    while (_held != null) {
      await _held!.future;
    }
    return _take();
  }

  /// The link if nobody has it this instant, else null. For work that would rather skip a turn than queue
  /// (the background watcher).
  void Function()? tryAcquire() => _held == null ? _take() : null;

  void Function() _take() {
    final c = _held = Completer<void>();
    return () {
      if (c.isCompleted) return;
      if (identical(_held, c)) _held = null;
      c.complete();
    };
  }
}
