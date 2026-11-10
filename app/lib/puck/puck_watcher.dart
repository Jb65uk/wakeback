// Tracks come over by themselves: while WakeBack is open, every so often the phone listens for its own pucks.
// One that's awake nearby with finished tracks waiting (its advert says how many) gets connected to, emptied
// into this phone's sessions, and left alone again. So: put the puck on the pad, open the app, and the sail is
// in the Sessions tab a minute later. It never queues for the Bluetooth link: if a puck's screen or Set up a
// puck has it, this skips a turn.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../dock/store.dart';
import 'puck_ble.dart';
import 'puck_pull.dart';

class PuckWatcher extends ChangeNotifier with WidgetsBindingObserver {
  DockStore Function() store;
  bool Function() enabled; // has pucks with keys, not demo

  /// A pull just finished: what came over (the Sessions tab reloads on this).
  void Function(PullReport r, int puck)? onPulled;

  PuckWatcher({required this.store, required this.enabled});

  Timer? _timer;
  bool _foreground = true, _running = false;

  /// What happened last, in a sentence, for the pucks card.
  String? lastEvent;

  /// Counts the pulls that brought something over or hit a problem: the home screen says so once for each.
  int pulls = 0;

  /// The puck being emptied right now (null when idle), and how far through (0..1).
  int? pulling;
  double progress = 0;

  static const every = Duration(seconds: 90);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _timer ??= Timer.periodic(every, (_) => tick());
    Future<void>.delayed(const Duration(seconds: 8), tick); // soon after the app opens, not instantly (let the UI settle)
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final was = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !was) tick(); // back on screen: have a look straight away
  }

  /// One round: listen for 6 s, pull from any of our pucks that has tracks waiting. Safe to call any time;
  /// [byHand] (the "Check for tracks now" button) says so when there was nothing to fetch.
  Future<void> tick({bool byHand = false}) async {
    if (_running || !_foreground || !enabled()) return;
    if (!await PuckBle.available()) {
      if (byHand) _say('Bluetooth is off.');
      return;
    }
    final release = PuckBle.link.tryAcquire();
    if (release == null) return;
    _running = true;
    try {
      final seen = <int, PuckSeen>{};
      var mine = 0;
      try {
        await for (final p in PuckBle.scan(timeout: const Duration(seconds: 6))) {
          if (!p.mine) continue;
          mine++;
          if (p.pending > 0) seen[p.puck] = p;
        }
      } catch (_) {
        return; // Bluetooth off, permission not given yet: the puck screen explains those; here we just wait
      }
      if (seen.isEmpty && byHand) _say(mine == 0 ? 'No puck of yours heard nearby. Is it awake?' : 'Nothing waiting on your puck.');
      for (final p in seen.values) {
        PuckBle? b;
        try {
          b = await PuckBle.connectTo(p);
          if (!b.authed) continue;
          pulling = p.puck;
          progress = 0;
          _say('Getting tracks from puck ${p.puck}…');
          final r = await PuckPull.all(b, store(), progress: (v) {
            // a redraw for every packet would be silly: every few percent is plenty
            if (v - progress >= 0.03 || v >= 1) {
              progress = v;
              notifyListeners();
            }
          });
          lastEvent = 'Puck ${p.puck}: ${r.sentence}';
          if (r.tracks > 0 || !r.ok) pulls++;
          onPulled?.call(r, p.puck);
        } on PuckException catch (e) {
          lastEvent = 'Puck ${p.puck}: ${e.message}';
        } catch (e) {
          lastEvent = 'Puck ${p.puck}: $e';
        } finally {
          await b?.disconnect();
          pulling = null;
          notifyListeners();
        }
      }
    } finally {
      _running = false;
      release();
    }
  }

  void _say(String s) {
    lastEvent = s;
    notifyListeners();
  }
}
