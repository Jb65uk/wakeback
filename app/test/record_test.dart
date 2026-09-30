// flutter test — the Record tab's track logic, and that a phone recording lands in Sessions like a puck's.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeback/dock/store.dart';
import 'package:wakeback/record/track_log.dart';

/// A boat reaching east at [kn] knots from the Marine Lake, one fix a second.
List<RawFix> reach(int t0, int secs, double kn, {double acc = 5, bool reportSpeed = true}) {
  const lat = 53.6532, lon0 = -3.0181;
  final degPerM = 1 / (111320 * math.cos(lat * math.pi / 180));
  return [
    for (var i = 0; i < secs; i++)
      RawFix(t0 + i * 1000, lat, lon0 + i * (kn / kMsToKn) * degPerM, acc, speedMs: reportSpeed ? kn / kMsToKn : null, heading: reportSpeed ? 90 : null),
  ];
}

void main() {
  final t0 = DateTime.utc(2026, 9, 27, 10, 0).millisecondsSinceEpoch;

  test('distance, top speed and time from a steady reach', () {
    final l = TrackLog();
    for (final f in reach(t0, 601, 5)) {
      l.add(f, recording: true);
    }
    // 5 kn for 600 s = 0.833 nm
    expect(l.distNm, closeTo(5 * 600 / 3600, 0.01));
    expect(l.maxKn, closeTo(5, 0.01));
    expect(l.sailedMs, 600000);
    expect(l.fixes.first.hdg, 90);
  });

  test('speed and heading worked out when the phone doesn\'t report them', () {
    final l = TrackLog();
    for (final f in reach(t0, 60, 6, reportSpeed: false)) {
      l.add(f, recording: true);
    }
    expect(l.fixes.last.sogKn, closeTo(6, 0.05));
    expect(l.fixes.last.hdg, closeTo(90, 1));
  });

  test('weak fixes, glitches and paused fixes are left out; pauses aren\'t sailing', () {
    final l = TrackLog(maxAcc: 20);
    final a = reach(t0, 61, 5);
    for (final f in a) {
      l.add(f, recording: true);
    }
    expect(l.add(RawFix(t0 + 61000, 53.65, -3.01, 45), recording: true), FixResult.weak);
    expect(l.add(RawFix(t0 + 62000, 53.70, -3.01, 5), recording: true), FixResult.glitch); // 5 km in a second
    final before = l.fixes.length;
    // paused for 5 minutes: shows speed, keeps nothing
    for (final f in reach(t0 + 70000, 300, 5)) {
      expect(l.add(f, recording: false), FixResult.still);
    }
    expect(l.fixes.length, before);
    l.newSegment();
    for (final f in reach(t0 + 400000, 61, 5)) {
      l.add(f, recording: true);
    }
    expect(l.sailedMs, 120000); // two 60 s legs, not the gap between them
    expect(l.distNm, closeTo(2 * 5 * 60 / 3600, 0.01)); // the jump back to the start of the 2nd leg isn't counted
  });

  test('sitting still doesn\'t add up miles from GPS wobble', () {
    final l = TrackLog();
    final rnd = math.Random(1);
    for (var i = 0; i < 600; i++) {
      l.add(RawFix(t0 + i * 1000, 53.6532 + (rnd.nextDouble() - .5) * 2e-5, -3.0181 + (rnd.nextDouble() - .5) * 2e-5, 6, speedMs: 0.1), recording: true);
    }
    expect(l.distNm, lessThan(0.02));
    expect(l.fixes.length, lessThan(100)); // a point every ~10 s, not every second
  });

  test('draft lines survive a restart', () {
    final l = TrackLog();
    for (final f in reach(t0, 61, 5)) {
      l.add(f, recording: true);
    }
    l.newSegment();
    for (final f in reach(t0 + 100000, 61, 5)) {
      l.add(f, recording: true);
    }
    final back = TrackLog()..restore([for (final f in l.fixes) Fix.fromDraftLine(f.draftLine)!]);
    expect(back.fixes.length, l.fixes.length);
    expect(back.distNm, closeTo(l.distNm, 1e-4)); // the draft keeps 7 decimals (~1 cm)
    expect(back.sailedMs, l.sailedMs);
    expect(back.seg, 2); // a resume after recovery starts a new segment
  });

  test('GPX has one segment per leg, speed in m/s', () {
    final l = TrackLog();
    for (final f in reach(t0, 10, 5)) {
      l.add(f, recording: true);
    }
    l.newSegment();
    for (final f in reach(t0 + 60000, 10, 5)) {
      l.add(f, recording: true);
    }
    final g = l.toGpx(name: 'Sail & race');
    expect('<trkseg>'.allMatches(g).length, 2);
    expect(g, contains('Sail &amp; race'));
    expect(g, contains('<time>2026-09-27T10:00:00.000Z</time>'));
    expect(g, contains('<speed>2.57</speed>'));
  });

  test('a phone recording lands in Sessions with stats, like a puck', () async {
    final dir = await Directory.systemTemp.createTemp('wakeback_rec');
    final store = DockStore(dir);
    await store.init();
    store
      ..ownerName = 'James'
      ..ownerIsPerson = true;
    final l = TrackLog();
    for (final f in reach(t0, 901, 6)) {
      l.add(f, recording: true);
    }
    final res = await store.upload('${l.fileBase()}.csv', utf8.encode(l.toCsv()));
    expect(res['ok'], true);
    expect('${res['session']}', startsWith('2026-09-27_'));
    final rows = await store.rowsFor('all');
    expect(rows, hasLength(1));
    expect(rows.first.distNm, closeTo(1.5, 0.05));
    expect(rows.first.maxKn, closeTo(6, 0.2));
    expect(rows.first.ownerName, 'James');
    await dir.delete(recursive: true);
  });

  test('your usual boat goes on your own tracks; a session\'s boat can be changed', () async {
    final dir = await Directory.systemTemp.createTemp('wakeback_boat');
    final store = DockStore(dir);
    await store.init();
    store
      ..ownerName = 'James'
      ..ownerIsPerson = true
      ..defaultBoat = 'Solo 5843';
    final l = TrackLog();
    for (final f in reach(t0, 61, 5)) {
      l.add(f, recording: true);
    }
    final res = await store.upload('${l.fileBase()}.csv', utf8.encode(l.toCsv()));
    final day = '${res['session']}', file = '${res['file']}';
    var ss = await store.sessions();
    expect((ss.single['boats'] as Map)[file], 'Solo 5843');
    // a mate's track (different owner) doesn't get my boat
    final r2 = await store.upload('puck3_${l.fileBase()}.csv', utf8.encode(l.toCsv()), ownerName: 'Dave');
    ss = await store.sessions();
    expect((ss.single['boats'] as Map).containsKey(r2['file']), false);
    // change it, then clear it
    expect((await store.trackSettings(day, file, {'boat': 'Laser'}))['boat'], 'Laser');
    ss = await store.sessions();
    expect((ss.single['boats'] as Map)[file], 'Laser');
    expect((ss.single['sharing'] as Map)[file], 'friends'); // visibility untouched
    await store.trackSettings(day, file, {'boat': ''});
    ss = await store.sessions();
    expect((ss.single['boats'] as Map).containsKey(file), false);
    await dir.delete(recursive: true);
  });
}
