// Getting the tracks off a puck: over Bluetooth, decoded on the phone, into this phone's sessions, then deleted
// from the puck once they're safely here. Used by the puck screen ("Get its tracks") and by the background
// watcher that does it by itself when a puck of yours is awake nearby with tracks waiting.
import 'dart:typed_data';

import '../dock/store.dart';
import 'puck_ble.dart';
import 'wbt.dart';

class PullReport {
  final int tracks, points;
  final List<String> problems;
  const PullReport(this.tracks, this.points, this.problems);
  bool get ok => problems.isEmpty;

  String get sentence => tracks == 0
      ? (problems.isEmpty ? 'Nothing new on the puck.' : problems.first)
      : '$tracks track${tracks == 1 ? '' : 's'} came over${problems.isEmpty ? '.' : '; ${problems.first}'}';
}

class PuckPull {
  /// Tracks that were cut off part-way (the puck went out of reach), by puck/name/size: the next pull carries on
  /// from where each stopped. Held while the app is running.
  static final _partial = <String, TrackBuffer>{};

  /// Pull every finished track from a connected, authenticated puck into [store]. [onStep] gets a line to show
  /// as it goes; [progress] gets 0..1 across all the tracks. Each track is deleted from the puck only after it's
  /// been written here. A track that's still being recorded is left alone.
  static Future<PullReport> all(PuckBle b, DockStore store, {void Function(String)? onStep, void Function(double)? progress}) async {
    final list = (await b.tracks()).where((t) => !t.open).toList();
    String keyOf(PuckTrack t) => '${b.puck}/${t.name}/${t.bytes}';
    final here = {for (final t in list) keyOf(t)};
    _partial.removeWhere((k, _) => k.startsWith('${b.puck}/') && !here.contains(k)); // gone from the puck since
    if (list.isEmpty) return const PullReport(0, 0, []);
    final totalBytes = list.fold<int>(0, (s, t) => s + t.bytes);
    var doneBytes = 0, tracks = 0, points = 0;
    final problems = <String>[];
    for (final t in list) {
      onStep?.call('Getting ${t.name} (${(t.bytes / 1024).round()} KB)…');
      Uint8List raw;
      final buf = _partial.putIfAbsent(keyOf(t), TrackBuffer.new);
      try {
        raw = await b.getTrack(t, into: buf, progress: (got, total) => progress?.call((doneBytes + got) / totalBytes));
        _partial.remove(keyOf(t));
      } on PuckException catch (e) {
        final pct = t.bytes > 0 ? (100 * buf.length / t.bytes).floor() : 0;
        problems.add(pct > 0 ? '${e.message} ($pct% of ${t.name} is here; it carries on from there next time.)' : e.message);
        break; // the link is probably the problem: don't grind through the rest
      }
      doneBytes += t.bytes;
      final csv = Wbt.toCsv(raw);
      if (csv == null) {
        // not a .wbt: an old CSV track from before the compact format, take it as it is
        await _keep(store, t.name, raw, b.puck);
      } else {
        final n = Wbt.points(raw);
        if (n < 10) {
          onStep?.call('${t.name} is too short to be a sail, binning it.');
        } else {
          await _keep(store, _csvName(t.name), csv, b.puck);
          points += n;
        }
      }
      tracks++;
      try {
        await b.done(t.name);
      } on PuckException catch (e) {
        problems.add('${t.name} is here but the puck wouldn\'t delete it: ${e.message}');
      }
    }
    progress?.call(1);
    return PullReport(tracks, points, problems);
  }

  static String _csvName(String n) => n.endsWith('.wbt') ? '${n.substring(0, n.length - 4)}.csv' : n;

  static Future<void> _keep(DockStore store, String name, Uint8List bytes, int puck) => store.upload(name, bytes, puck: 'puck$puck');
}
