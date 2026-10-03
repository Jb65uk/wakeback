// flutter test — runs the phone's dock for real (HTTP on localhost) and checks it
// behaves like server/app.py, then syncs two docks against each other.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeback/demo/fake_race.dart';
import 'package:wakeback/dock/pocket_dock.dart';
import 'package:wakeback/dock/badges.dart';
import 'package:wakeback/dock/stats.dart';
import 'package:wakeback/dock/tiles.dart';
import 'package:wakeback/dock/store.dart';
import 'package:wakeback/sync/server_sync.dart';

Future<Uint8List?> diskAssets(String name) async {
  final f = File('assets/web/$name');
  return await f.exists() ? f.readAsBytes() : null;
}

class Dock {
  late Directory dir;
  late DockStore store;
  late PocketDock dock;
  String get url => dock.localUrl;

  Future<void> start() async {
    dir = await Directory.systemTemp.createTemp('wakeback_test');
    store = DockStore(dir);
    await store.init();
    dock = PocketDock(store, diskAssets, DockSettings());
    await dock.start(port: 0, address: InternetAddress.loopbackIPv4);
  }

  Future<void> stop() async {
    await dock.stop();
    await dir.delete(recursive: true);
  }

  Future<(int, dynamic)> req(String method, String path, {Object? json}) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(method, Uri.parse('$url$path'));
      if (json != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(json));
      }
      final res = await r.close();
      final body = await utf8.decodeStream(res);
      dynamic parsed;
      try {
        parsed = jsonDecode(body);
      } catch (_) {
        parsed = body;
      }
      return (res.statusCode, parsed);
    } finally {
      c.close();
    }
  }

  Future<(int, dynamic)> upload(String filename, String content, {Map<String, String> fields = const {}}) async {
    const b = 'wakebackTestBoundary';
    final body = StringBuffer();
    fields.forEach((k, v) => body.write('--$b\r\nContent-Disposition: form-data; name="$k"\r\n\r\n$v\r\n'));
    body.write('--$b\r\nContent-Disposition: form-data; name="file"; filename="$filename"\r\nContent-Type: text/csv\r\n\r\n$content\r\n--$b--\r\n');
    final c = HttpClient();
    try {
      final r = await c.postUrl(Uri.parse('$url/api/upload'));
      r.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$b');
      r.add(utf8.encode(body.toString()));
      final res = await r.close();
      return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
    } finally {
      c.close();
    }
  }
}

/// /api/sessions without the per-track 'stats' (those are checked in their own test).
List<Map<String, dynamic>> noStats(Object? list) =>
    (list as List).map((s) => {...(s as Map).cast<String, dynamic>()}..remove('stats')).toList();

String shortCsv(DateTime t0, {int seed = 5}) {
  final rows = simBoat(4.5, seed, 0, 12, t0: t0, laps: 1);
  return toPuckCsv(rows.take(600).toList()); // one minute at 10 Hz
}

void main() {
  late Dock d;
  setUp(() async {
    d = Dock();
    await d.start();
  });
  tearDown(() => d.stop());

  test('serves the real viewer with Leaflet from the app, not the CDN', () async {
    final (s, body) = await d.req('GET', '/');
    expect(s, 200);
    expect(body as String, contains('/viewer/leaflet.js'));
    expect(body, isNot(contains('cdnjs.cloudflare.com/ajax/libs/leaflet')));
    expect((await d.req('GET', '/viewer/leaflet.js')).$1, 200);
    expect((await d.req('GET', '/dock')).$1, 200);
    expect((await d.req('GET', '/upload')).$1, 404); // phone-upload page removed
    expect((await d.req('GET', '/viewer/secret.txt')).$1, 404);
  });

  test('puck upload is filed by sailing date, clashes get -2, pucks page picks it up', () async {
    final t0 = DateTime.utc(2026, 9, 20, 10, 30);
    final (s, j) = await d.upload('puck4_103000.csv', shortCsv(t0), fields: {'puck': 'puck4'});
    expect(s, 200);
    expect(j['session'], '2026-09-20_southport-sc');
    expect(j['venue_name'], 'Southport SC (Marine Lake)');
    expect(j['file'], 'puck4_103000.csv');
    final (_, j2) = await d.upload('puck4_103000.csv', shortCsv(t0));
    expect(j2['file'], 'puck4_103000-2.csv');
    // a puck field adds the prefix when the filename lacks it
    final (_, j3) = await d.upload('log.csv', shortCsv(t0), fields: {'puck': 'puck7'});
    expect(j3['file'], 'puck7_log.csv');

    final (_, sessions) = await d.req('GET', '/api/sessions');
    expect(noStats(sessions), [
      {
        'id': '2026-09-20_southport-sc', 'date': '2026-09-20', 'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)',
        'venue_new': false, 'files': ['puck4_103000-2.csv', 'puck4_103000.csv', 'puck7_log.csv'], 'count': 3, 'races': 0, 'owners': {},
        'sharing': {}, 'mine': ['puck4_103000-2.csv', 'puck4_103000.csv', 'puck7_log.csv'],
      }
    ]);
    final (_, pk) = await d.req('GET', '/api/pucks');
    final p4 = (pk['pucks'] as List).firstWhere((p) => p['puck'] == 4);
    expect(p4['last_upload']['session'], '2026-09-20_southport-sc');
    final (s404, _) = await d.req('GET', '/api/sessions/2026-09-20_southport-sc/nope.csv');
    expect(s404, 404);
    final (sGet, csv) = await d.req('GET', '/api/sessions/2026-09-20_southport-sc/puck4_103000.csv');
    expect(sGet, 200);
    expect(csv as String, startsWith('t_ms,lat,lon,sog_kn,hdg,heel,pitch'));
  });

  test('refuses non-track files with the dock\'s message; tidies phone file names', () async {
    final (s, j) = await d.upload('photo.jpg', 'x');
    expect(s, 400);
    expect(j['error'], contains('Export GPX'));
    final gpx = toGpx('Steve', simBoat(4.3, 51, 20, 15, t0: DateTime.utc(2026, 9, 21, 9), laps: 1).take(600).toList());
    final (s2, j2) = await d.upload('Morning sail (2).GPX', gpx, fields: {'sailor': 'Steve'});
    expect(s2, 200);
    expect(j2['file'], 'Morning sail _2_.GPX');
    expect(j2['session'], '2026-09-21_southport-sc');
    final (_, crew) = await d.req('GET', '/api/sessions/2026-09-21_southport-sc/crew');
    expect(crew, {'Morning sail _2_.GPX': 'Steve'});
    expect((await d.req('GET', '/api/sailors')).$2, ['Steve']);
  });

  test('races, course and crew are cleaned exactly like app.py', () async {
    final (s, races) = await d.req('PUT', '/api/sessions/2026-09-20/races', json: [
      {'name': 'Race 2', 'start': 2000, 'end': 3000, 'gun': 0, 'marks': [{'lat': 'x', 'lon': 1}], 'lines': []},
      {'name': 'Race 1', 'start': '1000', 'end': 1500.9, 'gun': '1100',
        'marks': [{'id': 'w', 'name': 'Windward', 'lat': 53.65, 'lon': -3.01, 'side': 'stbd'}, {'lat': 95, 'lon': 0}],
        'lines': [{'kind': 'finish', 'a': {'lat': 53.6, 'lon': -3}, 'b': {'lat': 53.61, 'lon': -3.01}}, {'kind': 'start', 'a': {'lat': 1}}]},
      {'name': 'backwards', 'start': 5, 'end': 1},
      'junk',
    ]);
    expect(s, 200);
    expect(races, [
      {
        'name': 'Race 1', 'start': 1000, 'end': 1500,
        'marks': [{'id': 'w', 'name': 'Windward', 'lat': 53.65, 'lon': -3.01, 'side': 'stbd'}],
        'lines': [{'id': '', 'kind': 'finish', 'a': {'lat': 53.6, 'lon': -3.0}, 'b': {'lat': 53.61, 'lon': -3.01}}],
        'gun': 1100,
      },
      {'name': 'Race 2', 'start': 2000, 'end': 3000, 'marks': [], 'lines': []},
    ]);
    expect((await d.req('GET', '/api/sessions/2026-09-20/races')).$2, races);
    final (sBad, _) = await d.req('PUT', '/api/sessions/2026-09-20/races', json: {'not': 'a list'});
    expect(sBad, 400);

    final (_, meta) = await d.req('PUT', '/api/sessions/2026-09-20/meta', json: {
      'marks': [], 'gun': 0,
      'fixes': [{'k': 'puck1|123', 't': 123.7, 'kind': 'Tack'}, {'k': 'x', 't': 1, 'kind': 'Wobble'}],
    });
    expect(meta, {'marks': [], 'fixes': [{'k': 'puck1|123', 't': 123, 'kind': 'Tack'}], 'lines': []});

    final (_, crew) = await d.req('PUT', '/api/sessions/2026-09-20/crew', json: {'puck1': ' James ', 'puck2': '', 'puck3': null});
    expect(crew, {'puck1': 'James', 'puck3': 'None'}); // str(None) is truthy in Python too
  });

  test('the day\'s weather is kept and cleaned exactly like app.py', () async {
    final (s, meta) = await d.req('PUT', '/api/sessions/2026-09-20/meta', json: {
      'marks': [],
      'weather': {
        'src': 'Open-Meteo', 'lat': 53.65, 'lon': -3.01, 'got': 1790000000123.9,
        'pts': [
          [1789898400000, 225, 15.5, 21.2],
          [1789902000000.7, '-10', '16', null],
          [1789905600000, 230, -1, 20],
          [1789909200000, 235, 17],
          ['x', 1, 2, 3],
          [1789912800000, 400.5, 18.25, 300],
        ],
      },
    });
    expect(s, 200);
    // app.py's answer for the same request, verbatim
    expect(meta, {
      'fixes': [], 'lines': [], 'marks': [],
      'weather': {
        'got': 1790000000123, 'lat': 53.65, 'lon': -3.01, 'src': 'Open-Meteo',
        'pts': [[1789898400000, 225.0, 15.5, 21.2], [1789902000000, 350.0, 16.0, null], [1789909200000, 235.0, 17.0, null]],
      },
    });
    final (_, junk) = await d.req('PUT', '/api/sessions/2026-09-20/meta', json: {
      'weather': {'pts': [['bad']]}
    });
    expect(junk, {'fixes': [], 'lines': [], 'marks': []});
  });

  test('puck check-ins drive the Dock page', () async {
    final (s, j) = await d.req('POST', '/api/pucks/checkin',
        json: {'puck': 3, 'battery_mv': 4000, 'charging': 'charging', 'on_pad': true, 'free_kb': 12000, 'total_kb': 14336, 'fw': '0.3.1'});
    expect(s, 200);
    expect(j['time_ms'], isA<int>());
    expect((await d.req('POST', '/api/pucks/checkin', json: {'puck': 'x'})).$1, 400);
    expect((await d.req('POST', '/api/pucks/checkin', json: {'puck': 120})).$1, 400);
    final (_, pk) = await d.req('GET', '/api/pucks');
    final p3 = (pk['pucks'] as List).single;
    expect(p3['puck'], 3);
    expect(p3['docked'], true);
    expect(p3['battery_pct'], 78);
    expect(p3['charging'], 'charging');
    final (_, st) = await d.req('GET', '/api/dock/status');
    expect(st['can_manage_wifi'], false);
    expect(st['phone'], true);
    expect((await d.req('GET', '/api/hello')).$2['dock'], 'wakeback');
  });

  // fixed tracks so the answers can be checked against server/app.py word for word
  const south = 't_ms,lat,lon,sog_kn,hdg,heel,pitch\n1789900200000,53.6510000,-3.0110000,4.00,90,5.0,0.0\n1789900201000,53.6510100,-3.0109900,4.10,90,5.0,0.0\n';
  const far = 't_ms,lat,lon,sog_kn,hdg,heel,pitch\n1790150400000,53.3900000,-3.1900000,4.00,90,5.0,0.0\n1790150401000,53.3900100,-3.1899900,4.10,90,5.0,0.0\n';

  test('venues: found from where you sailed, somewhere new gets named, sessions can move (same answers as app.py)', () async {
    final (_, a) = await d.upload('puck4_103000.csv', south, fields: {'puck': 'puck4', 'owner_name': 'James', 'owner_email': 'j@example.com'});
    expect(a, {'file': 'puck4_103000.csv', 'ok': true, 'session': '2026-09-20_southport-sc', 'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)'});
    expect((await d.req('GET', '/api/sessions/2026-09-20_southport-sc/crew')).$2, {'puck4': 'James'}); // owner's own boat gets their name
    final (_, dd) = await d.upload('Mate.csv', far, fields: {'owner_name': 'Dave'});
    expect(dd, {'file': 'Mate.csv', 'ok': true, 'session': '2026-09-23_near-5339n-319w', 'venue': 'near-5339n-319w', 'venue_name': 'New venue near 53.39, -3.19'});
    final (_, list) = await d.req('GET', '/api/sessions');
    expect(noStats(list), [
      {'count': 1, 'date': '2026-09-23', 'files': ['Mate.csv'], 'id': '2026-09-23_near-5339n-319w', 'owners': {'Mate.csv': 'Dave'}, 'races': 0,
        'venue': 'near-5339n-319w', 'venue_name': 'New venue near 53.39, -3.19', 'venue_new': true, 'sharing': {'Mate.csv': 'friends'}, 'mine': []},
      {'count': 1, 'date': '2026-09-20', 'files': ['puck4_103000.csv'], 'id': '2026-09-20_southport-sc', 'owners': {'puck4_103000.csv': 'James'}, 'races': 0,
        'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)', 'venue_new': false, 'sharing': {'puck4_103000.csv': 'friends'}, 'mine': []},
    ]);
    expect(jsonEncode(list), isNot(contains('example.com'))); // emails never leave the dock
    expect((await d.req('GET', '/api/venues')).$2, [
      {'auto': true, 'id': 'near-5339n-319w', 'lat': 53.39, 'lon': -3.19, 'name': 'New venue near 53.39, -3.19', 'radius_m': 1500},
      {'auto': false, 'id': 'southport-sc', 'lat': 53.6503, 'lon': -3.0102, 'name': 'Southport SC (Marine Lake)', 'radius_m': 1500},
    ]);
    final (sPut, put) = await d.req('PUT', '/api/venues/near-5339n-319w', json: {'name': 'West Kirby SC'});
    expect(sPut, 200);
    expect(put, {'auto': false, 'id': 'near-5339n-319w', 'lat': 53.39, 'lon': -3.19, 'name': 'West Kirby SC', 'radius_m': 1500});
    expect((await d.req('PUT', '/api/venues/near-5339n-319w', json: {'name': '  '})).$1, 400);
    final (sAdd, add) = await d.req('POST', '/api/venues', json: {'name': 'Hollingworth Lake', 'lat': 53.64, 'lon': -2.09});
    expect(sAdd, 201);
    expect(add, {'auto': false, 'id': 'hollingworth-lake', 'lat': 53.64, 'lon': -2.09, 'name': 'Hollingworth Lake', 'radius_m': 1500});
    expect((await d.req('POST', '/api/venues', json: {'id': 'hollingworth-lake', 'name': 'Other', 'lat': 1, 'lon': 1})).$2['name'], 'Hollingworth Lake');
    expect((await d.req('POST', '/api/venues', json: {'name': 'Hollingworth Lake', 'lat': 53.7, 'lon': -2.1})).$2['id'], 'hollingworth-lake-2');
    final (sMove, mv) = await d.req('POST', '/api/sessions/2026-09-23_near-5339n-319w/move', json: {'venue': 'southport-sc'});
    expect(sMove, 200);
    expect(mv, {'session': '2026-09-23_southport-sc'});
    expect((await d.req('POST', '/api/sessions/2026-09-20_southport-sc/move', json: {'venue': 'nope'})).$1, 400);
    expect((await d.req('GET', '/api/sessions/2026-09-23_southport-sc/crew')).$2, {'Mate.csv': 'Dave'});
    final (_, st) = await d.req('GET', '/api/dock/status');
    expect(st['phone'], true);
    expect((await d.req('GET', '/api/qr/wifi.svg')).$1, 404); // phone-upload QR page is gone
  });

  test('phone dock: who am I, mine vs friends, sharing switch', () async {
    d.store
      ..ownerName = 'James'
      ..ownerEmail = 'james@example.com';
    d.dock.me = () => {'name': 'James', 'email': 'james@example.com'};
    expect((await d.req('GET', '/api/auth/me')).$2, {'accounts': false, 'user': {'name': 'James', 'email': 'james@example.com'}});
    await d.upload('puck1_103000.csv', south); // mine (profile owner)
    await d.upload('Mate.csv', south, fields: {'owner_name': 'Dave', 'owner_email': 'dave@x.com'}); // a friend's puck via my hotspot
    final (_, list) = await d.req('GET', '/api/sessions');
    final s = (list as List).single;
    expect(s['mine'], ['puck1_103000.csv']);
    expect(s['sharing'], {'puck1_103000.csv': 'friends', 'Mate.csv': 'friends'});
    expect(s['owners'], {'puck1_103000.csv': 'James', 'Mate.csv': 'Dave'});
    final (st, j) = await d.req('POST', '/api/sessions/2026-09-20_southport-sc/tracks/puck1_103000.csv', json: {'visibility': 'private'});
    expect(st, 200);
    expect(j, {'name': 'James', 'visibility': 'private'});
    expect((await d.req('POST', '/api/sessions/2026-09-20_southport-sc/tracks/puck1_103000.csv', json: {'visibility': 'x'})).$1, 400);
    expect(((await d.req('GET', '/api/sessions')).$2 as List).single['sharing']['puck1_103000.csv'], 'private');
    expect(await d.store.ownerOf('2026-09-20_southport-sc', 'puck1_103000.csv'), {'name': 'James', 'email': 'james@example.com', 'visibility': 'private'});
  });

  test('stats and league match server/stats.py to the decimal', () async {
    // expected values come from running server/stats.py on the same two fixture files
    final puck = await File('test/fixtures/stats_puck.csv').readAsString();
    final gpx = await File('test/fixtures/stats_phone.gpx').readAsString();
    expect(computeStats(puck, 'x.csv'), {'points': 1800, 'start_ms': 1789900200000, 'end_ms': 1789900499900, 'dist_nm': 0.191, 'max_kn': 7.38, 'avg_kn': 4.24, 'moving_s': 147, 'max_heel': 12.0, 'capsizes': 0});
    expect(computeStats(gpx, 'x.gpx'), {'points': 400, 'start_ms': 1789900200000, 'end_ms': 1789900599000, 'dist_nm': 0.377, 'max_kn': 4.06, 'avg_kn': 3.98, 'moving_s': 339});
    expect(computeStats('t_ms,lat,lon\n1,2,3\n', 'x.csv'), isNull);
    // with the day's weather (wind from 000 at 12 kn): upwind / downwind / VMG, same as stats.py
    final wx = {'pts': [for (var h = -1; h < 3; h++) [1789900200000 + h * 3600000, 0.0, 12.0, null]], 'got': 5};
    expect(computeStats(puck, 'x.csv', wx), {'points': 1800, 'start_ms': 1789900200000, 'end_ms': 1789900499900, 'dist_nm': 0.191, 'max_kn': 7.38, 'avg_kn': 4.24, 'moving_s': 147,
      'max_heel': 12.0, 'capsizes': 0, 'wind_kn': 12.0, 'up_kn': 1.7, 'down_kn': 5.5, 'vmg_kn': 1.19});
    expect(computeStats(gpx, 'x.gpx', wx), {'points': 400, 'start_ms': 1789900200000, 'end_ms': 1789900599000, 'dist_nm': 0.377, 'max_kn': 4.06, 'avg_kn': 3.98, 'moving_s': 339,
      'wind_kn': 12.0, 'up_kn': 3.98, 'vmg_kn': 2.83});
    // a capsize: 12 s over 80 deg counts once, 5 s doesn't
    final capCsv = StringBuffer('t_ms,lat,lon,sog_kn,hdg,heel,pitch\n');
    for (var i = 0; i < 400; i++) {
      final heel = (i >= 50 && i < 170) ? 85.0 : (i >= 300 && i < 350) ? -85.0 : 10.0;
      capCsv.writeln('${1789900200000 + i * 100},${53.65 + i * 1e-6},-3.01,3.0,90.0,$heel,1.0');
    }
    expect(computeStats(capCsv.toString(), 'x.csv')!['capsizes'], 1);

    d.store
      ..ownerName = 'James'
      ..ownerEmail = 'james@example.com';
    await d.upload('puck1_103000.csv', puck);
    await d.upload('Steve_phone.gpx', gpx, fields: {'owner_name': 'Steve', 'owner_email': 'steve@x.com'});
    final s = ((await d.req('GET', '/api/sessions')).$2 as List).single;
    expect(s['id'], '2026-09-20_southport-sc');
    expect(s['stats']['puck1_103000.csv']['dist_nm'], 0.191);
    expect(s['stats']['Steve_phone.gpx']['moving_s'], 339);
    expect(await File('${d.dir.path}/sessions/2026-09-20_southport-sc/stats.json').exists(), isTrue); // cached

    const ref = {'session': '2026-09-20_southport-sc', 'date': '2026-09-20', 'venue_name': 'Southport SC (Marine Lake)'};
    final (st, mine) = await d.req('GET', '/api/stats?period=all');
    expect(st, 200);
    expect(mine, {
      'period': 'all', 'sessions': 1, 'tracks': 1, 'dist_nm': 0.19, 'moving_h': 0.04,
      'max_kn': 7.38, 'max_track': {...ref, 'file': 'puck1_103000.csv'},
      'avg_kn': 4.24, 'best_avg_kn': 4.24, 'best_avg_track': {...ref, 'file': 'puck1_103000.csv'},
      'longest_nm': 0.191, 'longest_track': {...ref, 'file': 'puck1_103000.csv'},
      'venues': 1, 'favourite_venue': 'Southport SC (Marine Lake)', 'first_date': '2026-09-20', 'last_date': '2026-09-20',
      'by_month': [{'month': '2026-09', 'dist_nm': 0.19, 'sessions': 1, 'moving_s': 147}],
      'wind': [], 'max_heel': 12.0, 'heel_track': {...ref, 'file': 'puck1_103000.csv'}, 'capsizes': 0,
    });
    // both together (what summarise gives the league for a two-track person)
    final rows = await d.store.rowsFor('all');
    expect(summarise(rows)['avg_kn'], 4.06);
    expect(summarise(rows)['longest_track'], {...ref, 'file': 'Steve_phone.gpx'});
    // the day's weather arrives later: stats are redone and the wind section fills in
    await d.req('PUT', '/api/sessions/2026-09-20_southport-sc/meta', json: {'marks': [], 'lines': [], 'fixes': [], 'weather': {'src': 'test', 'lat': 53.65, 'lon': -3.01, 'got': 5, 'pts': wx['pts']}});
    final wrows = await d.store.rowsFor('all');
    final wsum = summarise(wrows);
    expect(wsum['wind'], [{'bin': '10-15', 'sessions': 1, 'avg_kn': 4.06, 'best_avg_kn': 4.24, 'max_kn': 7.38, 'moving_h': 0.14}]);
    expect(wsum['up_kn'], 3.98);
    expect(wsum['up_track'], {...ref, 'file': 'Steve_phone.gpx'});
    expect(wsum['down_kn'], 5.5);
    expect(wsum['vmg_kn'], 2.83);
    expect(wsum['avg_up_kn'], 3.29);
    expect(wsum['avg_down_kn'], 5.5);
    expect(wsum['capsizes'], 0);

    final (_, lg) = await d.req('GET', '/api/league');
    expect(lg['people'], [
      {'name': 'Steve', 'me': false, 'sessions': 1, 'dist_nm': 0.38, 'moving_h': 0.09, 'max_kn': 4.06, 'avg_kn': 3.98, 'best_avg_kn': 3.98, 'longest_nm': 0.377},
      {'name': 'James', 'me': true, 'sessions': 1, 'dist_nm': 0.19, 'moving_h': 0.04, 'max_kn': 7.38, 'avg_kn': 4.24, 'best_avg_kn': 4.24, 'longest_nm': 0.191},
    ]);
    // a period that starts after the sailing: nothing
    expect(periodStart('month', now: DateTime.utc(2026, 9, 15)), 1788220800000);
    expect(periodStart('year', now: DateTime.utc(2026, 9, 15)), 1767225600000);
    expect(((await d.req('GET', '/api/stats?period=month')).$2)['sessions'], DateTime.now().toUtc().isBefore(DateTime.utc(2026, 10)) ? 1 : 0);
  });

  test('personal bests and badges', () {
    StatRow row(String date, {double max = 5, double avg = 3, double dist = 4, int moving = 3600, String venue = 'Southport SC', int hour = 11, Map<String, dynamic> extra = const {}}) =>
        StatRow('${date}_x', date, 'x', venue, '$date.csv', {
          'max_kn': max, 'avg_kn': avg, 'dist_nm': dist, 'moving_s': moving,
          'start_ms': DateTime.parse('${date}T${hour.toString().padLeft(2, '0')}:00:00').millisecondsSinceEpoch, 'end_ms': 0, 'points': 10, ...extra,
        });
    final before = [row('2026-09-05', max: 6.1, avg: 3.5, dist: 8), row('2026-09-12', max: 5.5, avg: 3.9, dist: 6), row('2025-06-01', max: 7.0, avg: 3.0, dist: 12)];
    final fresh = [row('2026-09-19', max: 6.5, avg: 4.1, dist: 7)];
    final recs = newRecords(fresh, before, year: 2026);
    expect(recs.map((r) => '${r.title}|${r.value}|${r.scope}').toList(), [
      'Top speed|6.5 kn|this year', // 7.0 in 2025 still stands
      'Fastest average|4.1 kn|ever',
    ]);
    expect(newRecords(fresh, const [], year: 2026), isEmpty); // nothing to beat yet
    expect(newRecords(const [], before, year: 2026), isEmpty);

    final rows = [...before, ...fresh, row('2026-09-26', max: 8.2, dist: 16, moving: 5 * 3600, hour: 6, venue: 'West Kirby SC', extra: {'wind_kn': 22.0, 'capsizes': 1})];
    final b = {for (final x in badges(rows, summarise(rows))) x.id: x};
    expect(b['first']!.earned, isTrue);
    expect(b['ten']!.earned, isFalse);
    expect(b['ten']!.detail, '5 of 10');
    expect(b['kn6']!.earned, isTrue);
    expect(b['kn8']!.earned, isTrue);
    expect(b['kn10']!.earned, isFalse);
    expect(b['marathon']!.earned, isTrue);
    expect(b['allday']!.earned, isTrue);
    expect(b['dawn']!.earned, isTrue);
    expect(b['streak3']!.earned, isTrue); // 5, 12, 19, 26 Sep 2026 are four Saturdays running
    expect(b['streak6']!.earned, isFalse);
    expect(b['windy']!.earned, isTrue);
    expect(b['swimmer']!.earned, isTrue);
    expect(b['explorer']!.earned, isFalse);
    expect(badges(const [], summarise(const [])).single.earned, isFalse);
  });

  test('offline map tiles: served from the cache, geometry of a venue', () async {
    final cache = TileCache(Directory('${d.dir.path}/tiles'));
    d.dock.tiles = cache;
    // Southport at z14 -> the tile that holds the lake
    final around = TileCache.tilesAround(53.6503, -3.0102, 100, 14, 14);
    expect(around, contains((14, 8055, 5287))); // the lake sits right on a tile edge, so its neighbour comes too
    expect(around.length, inInclusiveRange(1, 4));
    // more zoom = more tiles, and a 2.5 km circle at z17 is a few hundred of them
    expect(TileCache.tilesAround(53.6503, -3.0102, 2500, 17, 17).length, inInclusiveRange(400, 1200));
    final f = File('${d.dir.path}/tiles/osm/14/8055/5287');
    await f.create(recursive: true);
    await f.writeAsBytes([1, 2, 3]);
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(Uri.parse('${d.url}/tiles/osm/14/8055/5287.png'))).close();
      expect(r.statusCode, 200);
      expect(r.headers.contentType?.mimeType, 'image/png');
      expect(await r.fold<List<int>>([], (a, b) => a..addAll(b)), [1, 2, 3]);
      expect((await (await c.getUrl(Uri.parse('${d.url}/tiles/nope/1/0/0.png'))).close()).statusCode, anyOf(404, 502));
      expect((await (await c.getUrl(Uri.parse('${d.url}/tiles/osm/1/9/9.png'))).close()).statusCode, anyOf(404, 502)); // off the map
    } finally {
      c.close();
    }
    expect(await cache.usage(), (3, 1));
    await cache.clear();
    expect(await cache.usage(), (0, 0));
  });

  test('old date-only folders are split into date + venue sessions', () async {
    final old = Directory('${d.dir.path}/sessions/2026-09-19');
    await old.create(recursive: true);
    await File('${old.path}/puck1_090000.csv').writeAsString(
        't_ms,lat,lon,sog_kn,hdg,heel,pitch\n1789812000000,53.6500000,-3.0100000,4.00,90,5.0,0.0\n1789812001000,53.6500100,-3.0099900,4.10,90,5.0,0.0\n');
    await File('${old.path}/meta.json').writeAsString('{"marks": [], "fixes": [], "lines": []}');
    await d.store.init(); // what happens when the app starts
    expect(noStats((await d.req('GET', '/api/sessions')).$2), [
      {'count': 1, 'date': '2026-09-19', 'files': ['puck1_090000.csv'], 'id': '2026-09-19_southport-sc', 'owners': {}, 'races': 0,
        'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)', 'venue_new': false, 'sharing': {}, 'mine': ['puck1_090000.csv']},
    ]);
    expect(await File('${d.dir.path}/sessions/2026-09-19_southport-sc/meta.json').exists(), true);
    expect(await old.exists(), false);
  });

  test('delete a track', () async {
    await d.upload('puck1_100000.csv', shortCsv(DateTime.utc(2026, 9, 22, 10)));
    expect((await d.req('DELETE', '/api/sessions/2026-09-22_southport-sc/puck1_100000.csv')).$1, 200);
    expect((await d.req('GET', '/api/sessions')).$2, isEmpty);
  });

  test('demo race morning has three pucks, a phone GPX and a laid course', () {
    final files = demoDayFiles(DateTime.utc(2026, 9, 27, 10, 30));
    expect(files.keys.toSet(), {'puck1_103000.csv', 'puck2_103000.csv', 'puck3_103000.csv', 'Steve_phone.gpx'});
    expect(files['puck1_103000.csv']!.split('\n').length, greaterThan(40000)); // ~1.5 h at 10 Hz
    final m = demoMeta();
    expect((m['marks'] as List).length, 3);
    expect((m['lines'] as List).length, 2);
  });

  test('sync: phone and server end up with everything; a clashing course asks', () async {
    final server = Dock();
    await server.start();
    try {
      d.store.ownerName = 'James'; // this phone's profile
      server.store.ownerName = 'Southport SC';
      server.store.ownerIsPerson = false; // a club dock
      final day = '2026-09-20_southport-sc';
      final t0 = DateTime.utc(2026, 9, 20, 10, 30);
      await d.upload('puck1_103000.csv', shortCsv(t0, seed: 1)); // on the phone
      await server.upload('puck2_103000.csv', shortCsv(t0, seed: 2)); // mate's, on the server
      await d.req('PUT', '/api/sessions/$day/crew', json: {'puck1': 'James'});
      await server.req('PUT', '/api/sessions/$day/crew', json: {'puck2': 'Dave'});
      await d.req('PUT', '/api/sessions/$day/races', json: [{'name': 'Race 1', 'start': 1, 'end': 2}]);
      await d.req('PUT', '/api/sessions/$day/meta', json: {
        'weather': {'src': 'Open-Meteo', 'pts': [[1789898400000, 225, 15.5, 21.2]]}
      });

      final sync = ServerSync(server.url, d.store);
      final days = await sync.compare();
      expect(days.single.phoneOnly, ['puck1_103000.csv']);
      expect(days.single.serverOnly, ['puck2_103000.csv']);
      final r = await sync.syncDay(days.single);
      expect(r.up, 1);
      expect(r.down, 1);
      expect(r.conflicts, isEmpty);

      for (final dock in [d, server]) {
        expect(((await dock.req('GET', '/api/sessions')).$2 as List).single['files'], ['puck1_103000.csv', 'puck2_103000.csv']);
        expect((await dock.req('GET', '/api/sessions/$day/crew')).$2, {'puck1': 'James', 'puck2': 'Dave'});
        // the phone's track keeps its owner on the server; the club's keeps the club
        expect(((await dock.req('GET', '/api/sessions')).$2 as List).single['owners'], {'puck1_103000.csv': 'James', 'puck2_103000.csv': 'Southport SC'});
        expect(((await dock.req('GET', '/api/sessions/$day/races')).$2 as List).single['name'], 'Race 1');
        expect((await dock.req('GET', '/api/sessions/$day/meta')).$2['weather']['pts'], [[1789898400000, 225.0, 15.5, 21.2]]);
      }
      expect((await sync.compare()).single.tracksInSync, true);

      // now both edit the races differently: sync must ask, then honour the choice
      await d.req('PUT', '/api/sessions/$day/races', json: [{'name': 'Phone race', 'start': 1, 'end': 2}]);
      await server.req('PUT', '/api/sessions/$day/races', json: [{'name': 'Server race', 'start': 1, 'end': 2}]);
      final again = (await sync.compare()).single;
      final r2 = await sync.syncDay(again);
      expect(r2.conflicts, ['races']);
      expect(r2.up + r2.down, 0);
      await sync.syncDay(again, resolve: {'races': 'server'});
      expect(((await d.req('GET', '/api/sessions/$day/races')).$2 as List).single['name'], 'Server race');
    } finally {
      await server.stop();
    }
  });

  test('sync: my own sail follows me to my other device as mine, and a delete isn\'t undone', () async {
    final server = Dock(), tablet = Dock();
    await server.start();
    await tablet.start();
    try {
      for (final s in [d.store, tablet.store, server.store]) {
        s.ownerName = 'James'; // the same person signed in on both devices
      }
      final day = '2026-09-20_southport-sc';
      final t0 = DateTime.utc(2026, 9, 20, 10, 30);
      await d.upload('phone_103000.csv', shortCsv(t0, seed: 1)); // recorded on the phone
      await server.upload('puck2_103000.csv', shortCsv(t0, seed: 2), fields: {'owner_name': 'Dave'}); // a mate's

      final up = await ServerSync(server.url, d.store).syncNew();
      expect(up.up, 1);
      expect(up.down, 1);

      // the tablet has nothing: syncNew brings both down, mine as mine and Dave's as Dave's
      final sync = ServerSync(server.url, tablet.store);
      final r = await sync.syncNew();
      expect(r.down, 2);
      expect(r.up, 0);
      final s = (await tablet.store.sessions()).single;
      expect(s['files'], ['phone_103000.csv', 'puck2_103000.csv']);
      expect(s['mine'], ['phone_103000.csv']);
      expect((await tablet.store.myStats('all'))['tracks'], 1);

      // nothing new: nothing moves
      final again = await sync.syncNew();
      expect(again.up + again.down, 0);

      // an older app filed my own sail as a mate's when it came down: the next sync takes it back
      await tablet.store.setOwner(day, 'phone_103000.csv', {'name': 'James', 'visibility': 'friends', 'remote': true});
      expect((await tablet.store.sessions()).single['mine'], isEmpty);
      await sync.syncNew();
      expect((await tablet.store.sessions()).single['mine'], ['phone_103000.csv']);

      // deleted from the server on the phone: the tablet doesn't send it back up
      expect((await server.req('DELETE', '/api/sessions/$day/phone_103000.csv')).$1, 200);
      final after = await sync.syncNew();
      expect(after.up, 0);
      expect(((await server.req('GET', '/api/sessions')).$2 as List).single['files'], ['puck2_103000.csv']);
    } finally {
      await server.stop();
      await tablet.stop();
    }
  });

  test('sync: venues match up both ways before tracks move', () async {
    final server = Dock();
    await server.start();
    try {
      await d.upload('Mate.csv', far); // phone finds a new venue and you name it
      await d.req('PUT', '/api/venues/near-5339n-319w', json: {'name': 'West Kirby SC'});
      await server.req('POST', '/api/venues', json: {'name': 'Hollingworth Lake', 'lat': 53.64, 'lon': -2.09});
      final sync = ServerSync(server.url, d.store);
      final days = await sync.compare(); // syncs venues first
      expect(((await server.req('GET', '/api/venues')).$2 as List).map((v) => v['name']), containsAll(['West Kirby SC', 'Hollingworth Lake']));
      expect(((await d.req('GET', '/api/venues')).$2 as List).map((v) => v['name']), containsAll(['West Kirby SC', 'Hollingworth Lake']));
      await sync.syncDay(days.single);
      expect(((await server.req('GET', '/api/sessions')).$2 as List).single['id'], '2026-09-23_near-5339n-319w');
      expect(((await server.req('GET', '/api/sessions')).$2 as List).single['venue_name'], 'West Kirby SC');
    } finally {
      await server.stop();
    }
  });

  test('sync reports a server that isn\'t WakeBack', () async {
    final sync = ServerSync('${d.url}/viewer', d.store);
    await expectLater(sync.compare(), throwsA(isA<SyncException>()));
  });
}
