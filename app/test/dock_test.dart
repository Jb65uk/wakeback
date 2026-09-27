// flutter test — runs the phone's dock for real (HTTP on localhost) and checks it
// behaves like server/app.py, then syncs two docks against each other.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeback/demo/fake_race.dart';
import 'package:wakeback/dock/pocket_dock.dart';
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
    expect(sessions, [
      {
        'id': '2026-09-20_southport-sc', 'date': '2026-09-20', 'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)',
        'venue_new': false, 'files': ['puck4_103000-2.csv', 'puck4_103000.csv', 'puck7_log.csv'], 'count': 3, 'races': 0, 'owners': {},
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
    expect(list, [
      {'count': 1, 'date': '2026-09-23', 'files': ['Mate.csv'], 'id': '2026-09-23_near-5339n-319w', 'owners': {'Mate.csv': 'Dave'}, 'races': 0,
        'venue': 'near-5339n-319w', 'venue_name': 'New venue near 53.39, -3.19', 'venue_new': true},
      {'count': 1, 'date': '2026-09-20', 'files': ['puck4_103000.csv'], 'id': '2026-09-20_southport-sc', 'owners': {'puck4_103000.csv': 'James'}, 'races': 0,
        'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)', 'venue_new': false},
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

  test('old date-only folders are split into date + venue sessions', () async {
    final old = Directory('${d.dir.path}/sessions/2026-09-19');
    await old.create(recursive: true);
    await File('${old.path}/puck1_090000.csv').writeAsString(
        't_ms,lat,lon,sog_kn,hdg,heel,pitch\n1789812000000,53.6500000,-3.0100000,4.00,90,5.0,0.0\n1789812001000,53.6500100,-3.0099900,4.10,90,5.0,0.0\n');
    await File('${old.path}/meta.json').writeAsString('{"marks": [], "fixes": [], "lines": []}');
    await d.store.init(); // what happens when the app starts
    expect((await d.req('GET', '/api/sessions')).$2, [
      {'count': 1, 'date': '2026-09-19', 'files': ['puck1_090000.csv'], 'id': '2026-09-19_southport-sc', 'owners': {}, 'races': 0,
        'venue': 'southport-sc', 'venue_name': 'Southport SC (Marine Lake)', 'venue_new': false},
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
