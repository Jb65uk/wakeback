// Tracks come over by themselves: while WakeBack is open, every so often the phone listens for its own pucks.
// One that's awake nearby with finished tracks waiting (its advert says how many) gets connected to, emptied
// into this phone's sessions, and left alone again. So: put the puck on the pad, open the app, and the sail is
// in the Sessions tab a minute later. Nothing happens while the puck screen has the link, or while a pull is
// already running.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../dock/store.dart';
import 'puck_ble.dart';
import 'puck_pull.dart';

class PuckWatcher extends ChangeNotifier with WidgetsBindingObserver {
  DockStore Function() store;
  bool Function() enabled; // signed in with pucks, not demo, etc.

  /// A pull just finished: what came over (the Sessions tab reloads on this).
  void Function(PullReport r, int puck)? onPulled;

  PuckWatcher({required this.store, required this.enabled});

  Timer? _timer;
  bool _foreground = true, _running = false;

  /// What happened last, in a sentence, for the pucks card.
  String? lastEvent;
  DateTime? lastPull;

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

  /// One round: listen for 6 s, pull from any of our pucks that has tracks waiting. Safe to call any time.
  Future<void> tick() async {
    if (_running || !_foreground || PuckBle.busy || !enabled()) return;
    if (!await PuckBle.available()) return;
    _running = true;
    try {
      final seen = <int, PuckSeen>{};
      try {
        await for (final p in PuckBle.scan(timeout: const Duration(seconds: 6))) {
          if (p.mine && p.pending > 0) seen[p.puck] = p;
        }
      } catch (_) {
        return; // Bluetooth off, permission not given yet: the puck screen explains those; here we just wait
      }
      for (final p in seen.values) {
        if (PuckBle.busy) return;
        PuckBle.busy = true;
        PuckBle? b;
        try {
          b = await PuckBle.connectTo(p);
          if (!b.authed) continue;
          lastEvent = 'Getting tracks from puck ${p.puck}…';
          notifyListeners();
          final r = await PuckPull.all(b, store());
          lastPull = DateTime.now();
          lastEvent = 'Puck ${p.puck}: ${r.sentence}';
          onPulled?.call(r, p.puck);
        } on PuckException catch (e) {
          lastEvent = 'Puck ${p.puck}: ${e.message}';
        } catch (e) {
          lastEvent = 'Puck ${p.puck}: $e';
        } finally {
          await b?.disconnect();
          PuckBle.busy = false;
          notifyListeners();
        }
      }
    } finally {
      _running = false;
    }
  }
}
