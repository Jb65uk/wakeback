// Session storage + all the dock's rules, ported line for line from server/app.py
// so the phone files, cleans and reports things exactly like the dock Pi.
//
// Layout (same as the dock):  <data>/sessions/<YYYY-MM-DD>/<puckN_HHMMSS.csv | *.gpx | races.json | meta.json | crew.json>
//                             <data>/pucks.json
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final RegExp _safeRe = RegExp(r'^[A-Za-z0-9._ -]+$');

/// app.py's SAFE check, plus no "." / ".." (so nothing outside the sessions folder can be reached).
class _Safe {
  const _Safe();
  bool hasMatch(String s) => _safeRe.hasMatch(s) && s != '.' && s != '..';
}

const safeName = _Safe();
final RegExp _puckRe = RegExp(r'^puck[_ -]?(\d+)', caseSensitive: false);

class DockError implements Exception {
  final int status;
  final String message;
  const DockError(this.status, this.message);
  @override
  String toString() => message;
}

String baseName(String p) => p.replaceAll('\\', '/').split('/').last;

bool isTrack(String name) {
  final l = name.toLowerCase();
  return l.endsWith('.csv') || l.endsWith('.gpx');
}

/// Python's str() for the values JSON can give us.
String pyStr(Object? v) {
  if (v == null) return 'None';
  if (v is bool) return v ? 'True' : 'False';
  return v.toString();
}

String cut(String s, int n) => s.length <= n ? s : s.substring(0, n);

/// Python float(): numbers, or strings that parse. Anything else throws.
double pyFloat(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.parse(v.trim());
  throw const FormatException('not a number');
}

/// Python int(): ints, floats (truncated), or integer strings. Anything else throws.
int pyInt(Object? v) {
  if (v is bool) return v ? 1 : 0;
  if (v is int) return v;
  if (v is double) {
    if (v.isNaN || v.isInfinite) throw const FormatException('bad number');
    return v.truncate();
  }
  if (v is String) return int.parse(v.trim());
  throw const FormatException('not an int');
}

/// Python truthiness for JSON values.
bool pyTruthy(Object? v) {
  if (v == null || v == false) return false;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

// ------------------------------------------------------------------ cleaners (app.py)

List<Map<String, dynamic>> cleanMarks(Object? ms) {
  final out = <Map<String, dynamic>>[];
  if (ms is! List) return out;
  for (final m in ms.take(30)) {
    try {
      if (m is! Map) continue;
      final lat = pyFloat(m['lat']), lon = pyFloat(m['lon']);
      if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)) continue;
      out.add({
        'id': cut(pyStr(m.containsKey('id') ? m['id'] : ''), 16),
        'name': cut(pyStr(m.containsKey('name') ? m['name'] : 'Mark'), 30),
        'lat': lat,
        'lon': lon,
        'side': m['side'] == 'stbd' ? 'stbd' : 'port',
      });
    } catch (_) {}
  }
  return out;
}

List<Map<String, dynamic>> cleanLines(Object? ls) {
  final out = <Map<String, dynamic>>[];
  if (ls is! List) return out;
  for (final l in ls.take(6)) {
    try {
      if (l is! Map) continue;
      final ends = <String, dynamic>{};
      for (final w in ['a', 'b']) {
        final e = l[w];
        if (e is! Map) throw const FormatException('end');
        final lat = pyFloat(e['lat']), lon = pyFloat(e['lon']);
        if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)) throw const FormatException('range');
        ends[w] = {'lat': lat, 'lon': lon};
      }
      final kind = l['kind'];
      out.add({
        'id': cut(pyStr(l.containsKey('id') ? l['id'] : ''), 16),
        'kind': (kind == 'start' || kind == 'finish' || kind == 'both') ? kind : 'start',
        ...ends,
      });
    } catch (_) {}
  }
  return out;
}

int? cleanGun(Object? v) {
  if (!pyTruthy(v)) return null;
  try {
    return pyInt(v);
  } catch (_) {
    return null;
  }
}

// LiPo resting voltage -> rough %
const List<List<double>> _lipo = [
  [4.20, 100], [4.10, 90], [4.00, 78], [3.90, 62], [3.80, 45], [3.75, 35],
  [3.70, 22], [3.65, 12], [3.60, 6], [3.50, 2], [3.30, 0],
];

/// Python's round(): halves go to the even number.
int pyRound(double x) {
  final f = x.floorToDouble(), d = x - f, i = f.toInt();
  if (d > 0.5) return i + 1;
  if (d < 0.5) return i;
  return i.isEven ? i : i + 1;
}

int pctFromMv(num mv) {
  final v = mv / 1000;
  if (v >= _lipo[0][0]) return 100;
  for (var i = 0; i < _lipo.length - 1; i++) {
    final v1 = _lipo[i][0], p1 = _lipo[i][1], v2 = _lipo[i + 1][0], p2 = _lipo[i + 1][1];
    if (v >= v2) return pyRound(p2 + (p1 - p2) * (v - v2) / (v1 - v2));
  }
  return 0;
}

// ------------------------------------------------------------------ the store

class DockStore {
  final Directory data; // the equivalent of wakeback/data
  DockStore(this.data);

  Directory get sessionsDir => Directory('${data.path}/sessions');
  File get _pucksFile => File('${data.path}/pucks.json');
  Directory dayDir(String day) => Directory('${sessionsDir.path}/$day');

  /// How many pucks the club has, so ones never seen still get a row (WAKEBACK_FLEET).
  int fleet = 0;

  Future<void> init() => sessionsDir.create(recursive: true);

  // one writer at a time (app.py uses a threading.Lock)
  Future<void> _lock = Future.value();
  Future<T> locked<T>(Future<T> Function() fn) {
    final prev = _lock;
    final gate = Completer<void>();
    _lock = gate.future;
    return prev.then((_) => fn()).whenComplete(gate.complete);
  }

  Future<Object?> _readJson(File f) async {
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(File f, Object value) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(value), flush: true);
    await tmp.rename(f.path);
  }

  Future<List<String>> _days() async {
    if (!await sessionsDir.exists()) return [];
    final out = <String>[];
    await for (final e in sessionsDir.list(followLinks: false)) {
      if (e is Directory) out.add(baseName(e.path));
    }
    return out;
  }

  Future<List<String>> trackFiles(String day) async {
    final d = dayDir(day);
    if (!await d.exists()) return [];
    final out = <String>[];
    await for (final e in d.list(followLinks: false)) {
      final n = baseName(e.path);
      if (e is File && isTrack(n)) out.add(n);
    }
    out.sort();
    return out;
  }

  // ---- GET /api/sessions
  Future<List<Map<String, dynamic>>> sessions() async {
    final days = await _days();
    days.sort((a, b) => b.compareTo(a)); // newest first, like sorted(..., reverse=True)
    final out = <Map<String, dynamic>>[];
    for (final day in days) {
      final files = await trackFiles(day);
      if (files.isEmpty) continue;
      var races = 0;
      final r = await _readJson(File('${dayDir(day).path}/races.json'));
      if (r is List) races = r.length;
      out.add({'id': day, 'files': files, 'count': files.length, 'races': races});
    }
    return out;
  }

  Future<File> trackFile(String day, String name) async {
    if (!safeName.hasMatch(day) || !safeName.hasMatch(name)) throw const DockError(400, 'bad name');
    final f = File('${dayDir(day).path}/$name');
    if (!await f.exists()) throw const DockError(404, 'not found');
    return f;
  }

  /// The sailing day of a track, from its first timestamp (CSV t_ms in UTC, or GPX <time> as written —
  /// exactly what app.py files it under). Null if there isn't one.
  static String? firstDay(Uint8List bytes, String name) {
    try {
      if (name.toLowerCase().endsWith('.gpx')) {
        final head = latin1.decode(bytes.length > 4000 ? bytes.sublist(0, 4000) : bytes);
        final m = RegExp(r'<time>([^<]+)</time>').firstMatch(head);
        if (m == null) return null;
        final s = m.group(1)!.trim();
        DateTime.parse(s); // validity check; Python keeps the date as written, offset or not
        return s.substring(0, 10);
      }
      final t = firstTimestamp(bytes, name);
      return t == null ? null : dayOf(t);
    } catch (_) {
      return null;
    }
  }

  /// First timestamp in a CSV (t_ms), as UTC.
  static DateTime? firstTimestamp(Uint8List bytes, String name) {
    try {
      final head = latin1.decode(bytes.length > 4000 ? bytes.sublist(0, 4000) : bytes);
      if (name.toLowerCase().endsWith('.gpx')) {
        final m = RegExp(r'<time>([^<]+)</time>').firstMatch(head);
        return m == null ? null : DateTime.parse(m.group(1)!.trim()).toUtc();
      }
      final lines = const LineSplitter().convert(head);
      if (lines.length < 2) return null;
      final cols = lines[0].split(',').map((c) => c.trim().toLowerCase()).toList();
      var ti = cols.indexWhere((c) => c.startsWith('t'));
      if (ti < 0) ti = 0;
      var v = double.parse(lines[1].split(',')[ti].trim());
      if (v > 1e12) v /= 1000;
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(), isUtc: true);
    } catch (_) {
      return null;
    }
  }

  static String dayOf(DateTime utc) =>
      '${utc.year.toString().padLeft(4, '0')}-${utc.month.toString().padLeft(2, '0')}-${utc.day.toString().padLeft(2, '0')}';

  /// Tidy a filename like app.py ("Morning sail (2).GPX" -> "Morning sail _2_.GPX").
  static String tidyName(String filename) {
    var name = baseName(filename).replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '_');
    name = name.replaceAll(RegExp(r'^[ ._]+|[ ._]+$'), '');
    return name.isEmpty ? 'track.gpx' : name;
  }

  // ---- POST /api/upload
  Future<Map<String, dynamic>> upload(String filename, Uint8List bytes, {String puck = '', String sailor = ''}) async {
    var name = tidyName(filename);
    if (!isTrack(name)) {
      throw const DockError(400, 'That file isn\'t a GPX or CSV track. In your sailing app, look for "Export GPX".');
    }
    if (puck.isNotEmpty && !name.toLowerCase().startsWith(puck.toLowerCase())) name = '${puck}_$name';
    final day = firstDay(bytes, name) ?? dayOf(DateTime.now().toUtc());
    return locked(() async {
      final dir = dayDir(day);
      await dir.create(recursive: true);
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
      var dest = File('${dir.path}/$name');
      var n = 1;
      while (await dest.exists()) {
        n++;
        dest = File('${dir.path}/$base-$n$ext');
      }
      final tmp = File('${sessionsDir.path}/.incoming_$name');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(dest.path);
      final fname = baseName(dest.path);
      final pm = _puckRe.firstMatch(fname);
      if (pm != null) {
        final key = 'puck${int.parse(pm.group(1)!)}';
        final m = await _loadPucks();
        final r = (m[key] as Map<String, dynamic>?) ?? <String, dynamic>{};
        r['last_upload'] = {'time': DateTime.now().millisecondsSinceEpoch, 'session': day, 'file': fname, 'bytes': bytes.length};
        m[key] = r;
        await _writeJson(_pucksFile, m);
      }
      final who = cut(sailor.trim(), 40);
      if (who.isNotEmpty) {
        final cf = File('${dir.path}/crew.json');
        final j = await _readJson(cf);
        final crew = j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
        crew[fname] = who;
        await _writeJson(cf, crew);
      }
      return {'ok': true, 'session': day, 'file': fname};
    });
  }

  /// Put a track into a day exactly as named (used when syncing down from the server).
  Future<bool> putTrack(String day, String name, Uint8List bytes) async {
    if (!safeName.hasMatch(day) || !safeName.hasMatch(name) || !isTrack(name)) return false;
    return locked(() async {
      final f = File('${dayDir(day).path}/$name');
      if (await f.exists()) return false;
      await f.parent.create(recursive: true);
      final tmp = File('${sessionsDir.path}/.incoming_$name');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
      return true;
    });
  }

  /// Move a track to where the server filed it (sync), so both sides agree.
  Future<void> moveTrack(String day, String name, String toDay, String toName) async {
    final f = await trackFile(day, name);
    if (!safeName.hasMatch(toDay) || !safeName.hasMatch(toName)) throw const DockError(400, 'bad name');
    await locked(() async {
      final dest = File('${dayDir(toDay).path}/$toName');
      await dest.parent.create(recursive: true);
      if (await dest.exists()) {
        await f.delete(); // server's copy is already here
      } else {
        await f.rename(dest.path);
      }
    });
  }

  // ---- DELETE /api/sessions/<day>/<name>
  Future<void> deleteTrack(String day, String name) async {
    final f = await trackFile(day, name);
    await f.delete();
  }

  // ---- meta / races / crew (raw, as stored)
  Future<Map<String, dynamic>> getMeta(String day) async {
    _checkDay(day);
    final j = await _readJson(File('${dayDir(day).path}/meta.json'));
    return j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<List<dynamic>> getRaces(String day) async {
    _checkDay(day);
    final j = await _readJson(File('${dayDir(day).path}/races.json'));
    return j is List ? j : <dynamic>[];
  }

  Future<Map<String, dynamic>> getCrew(String day) async {
    _checkDay(day);
    final j = await _readJson(File('${dayDir(day).path}/crew.json'));
    return j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
  }

  void _checkDay(String day) {
    if (!safeName.hasMatch(day)) throw const DockError(400, 'bad day');
  }

  // ---- PUT meta
  Future<Map<String, dynamic>> putMeta(String day, Object? body) async {
    _checkDay(day);
    if (body is! Map) throw const DockError(400, 'expected an object');
    final fixes = <Map<String, dynamic>>[];
    final fx = body['fixes'];
    if (fx is List) {
      for (final f in fx.take(2000)) {
        try {
          if (f is! Map) continue;
          final kind = f['kind'];
          if (kind == 'Tack' || kind == 'Gybe' || kind == 'Mark' || kind == 'none') {
            if (!f.containsKey('k')) continue;
            fixes.add({'k': cut(pyStr(f['k']), 80), 't': pyInt(f['t']), 'kind': kind});
          }
        } catch (_) {}
      }
    }
    final clean = <String, dynamic>{'marks': cleanMarks(body['marks']), 'fixes': fixes, 'lines': cleanLines(body['lines'])};
    final gun = cleanGun(body['gun']);
    if (gun != null && gun != 0) clean['gun'] = gun;
    await locked(() => _writeJson(File('${dayDir(day).path}/meta.json'), clean));
    return clean;
  }

  // ---- PUT races
  Future<List<Map<String, dynamic>>> putRaces(String day, Object? body) async {
    _checkDay(day);
    if (body is! List) throw const DockError(400, 'expected a list');
    final clean = <Map<String, dynamic>>[];
    for (final r in body) {
      try {
        if (r is! Map) continue;
        final st = pyInt(r['start']), en = pyInt(r['end']);
        if (en > st) {
          final race = <String, dynamic>{
            'name': cut(pyStr(r.containsKey('name') ? r['name'] : 'Race'), 40),
            'start': st,
            'end': en,
            'marks': cleanMarks(r['marks']),
            'lines': cleanLines(r['lines']),
          };
          final gun = cleanGun(r['gun']);
          if (gun != null && gun != 0) race['gun'] = gun;
          clean.add(race);
        }
      } catch (_) {}
    }
    clean.sort((a, b) => (a['start'] as int).compareTo(b['start'] as int));
    await locked(() => _writeJson(File('${dayDir(day).path}/races.json'), clean));
    return clean;
  }

  // ---- PUT crew
  Future<Map<String, dynamic>> putCrew(String day, Object? body) async {
    _checkDay(day);
    if (body is! Map) throw const DockError(400, 'expected an object');
    final clean = <String, dynamic>{};
    body.forEach((k, v) {
      final s = pyStr(v).trim();
      if (s.isNotEmpty) clean[cut(pyStr(k), 80)] = cut(s, 40);
    });
    await locked(() => _writeJson(File('${dayDir(day).path}/crew.json'), clean));
    return clean;
  }

  /// Write races/meta/crew exactly as given (already cleaned by the server) — used by sync.
  Future<void> putRaw(String day, String what, Object value) async {
    _checkDay(day);
    if (!const {'races', 'meta', 'crew'}.contains(what)) throw const DockError(400, 'bad kind');
    await locked(() => _writeJson(File('${dayDir(day).path}/$what.json'), value));
  }

  // ---- GET /api/sailors
  Future<List<String>> sailors() async {
    final names = <String>{};
    for (final day in await _days()) {
      final j = await _readJson(File('${dayDir(day).path}/crew.json'));
      if (j is Map) {
        for (final v in j.values) {
          names.add(pyStr(v));
        }
      }
    }
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  // ------------------------------------------------------------------ pucks

  Future<Map<String, dynamic>> _loadPucks() async {
    final j = await _readJson(_pucksFile);
    if (j is! Map) return <String, dynamic>{};
    return j.map((k, v) => MapEntry('$k', v is Map ? v.cast<String, dynamic>() : <String, dynamic>{}));
  }

  static const int onlineSecs = 90; // a docked puck checks in every ~30 s; three missed = gone

  // ---- POST /api/pucks/checkin
  Future<Map<String, dynamic>> checkin(Object? body) async {
    final b = body is Map ? body : const {};
    int puckNo;
    try {
      puckNo = int.parse(pyStr(b.containsKey('puck') ? b['puck'] : '').replaceAll('puck', '').trim());
    } catch (_) {
      throw const DockError(400, 'puck number missing');
    }
    if (puckNo < 1 || puckNo > 99) throw const DockError(400, 'puck number out of range');
    final now = DateTime.now().millisecondsSinceEpoch;
    await locked(() async {
      final m = await _loadPucks();
      final r = (m['puck$puckNo'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      for (final k in ['battery_mv', 'free_kb', 'total_kb', 'pending', 'rssi']) {
        final v = b[k];
        if (v is num || v is bool) r[k] = v is bool ? (v ? 1 : 0) : v;
      }
      final ch = b['charging'];
      if (ch == 'charging' || ch == 'full' || ch == 'not') r['charging'] = ch;
      if (b['fw'] is String) r['fw'] = cut(b['fw'] as String, 16);
      r['on_pad'] = pyTruthy(b.containsKey('on_pad') ? b['on_pad'] : true);
      r['last_seen'] = now;
      if (r['on_pad'] == true) r['last_on_pad'] = now;
      m['puck$puckNo'] = r;
      await _writeJson(_pucksFile, m);
    });
    return {'ok': true, 'time_ms': now};
  }

  Future<String?> _lastSailor(String session, String? fname) async {
    final j = await _readJson(File('${dayDir(session).path}/crew.json'));
    if (j is! Map) return null;
    final pm = RegExp(r'^(puck\d+)', caseSensitive: false).firstMatch(fname ?? '');
    final a = j[pm != null ? pm.group(1)!.toLowerCase() : ''];
    if (a != null && pyTruthy(a)) return pyStr(a);
    final b = j[fname];
    return b == null ? null : pyStr(b);
  }

  // ---- GET /api/pucks
  Future<Map<String, dynamic>> pucks() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final m = await _loadPucks();
    // fall back to the files on disk for last upload (sessions copied in by hand, demo data)
    for (final day in (await _days()).where(safeName.hasMatch)) {
      final dd = dayDir(day);
      await for (final e in dd.list(followLinks: false)) {
        if (e is! File) continue;
        final fn = baseName(e.path);
        final pm = _puckRe.firstMatch(fn);
        if (pm == null || !isTrack(fn)) continue;
        final key = 'puck${int.parse(pm.group(1)!)}';
        final r = (m[key] as Map<String, dynamic>?) ?? <String, dynamic>{};
        m[key] = r;
        final st = await e.stat();
        final mt = st.modified.millisecondsSinceEpoch;
        final lu = r['last_upload'] is Map ? (r['last_upload'] as Map).cast<String, dynamic>() : null;
        final luSession = pyStr(lu?['session'] ?? '');
        final luGone = lu == null || !await File('${dayDir(luSession).path}/${pyStr(lu['file'] ?? '')}').exists();
        if (lu == null ||
            luSession.compareTo(day) < 0 ||
            (luSession == day && ((lu['time'] ?? 0) as num) < mt && luGone)) {
          r['last_upload'] = {'time': mt, 'session': day, 'file': fn, 'bytes': st.size};
        }
      }
    }
    for (var n = 1; n <= fleet; n++) {
      m.putIfAbsent('puck$n', () => <String, dynamic>{});
    }
    final keys = m.keys.where((k) => RegExp(r'^puck\d+$').hasMatch(k)).toList()
      ..sort((a, b) => int.parse(a.substring(4)).compareTo(int.parse(b.substring(4))));
    final out = <Map<String, dynamic>>[];
    for (final key in keys) {
      final r = m[key] as Map<String, dynamic>;
      final seen = r['last_seen'] as num?;
      final docked = r['on_pad'] == true && seen != null && now - seen < onlineSecs * 1000;
      final lu = r['last_upload'] is Map ? (r['last_upload'] as Map).cast<String, dynamic>() : null;
      Map<String, dynamic>? luOut;
      if (lu != null) {
        luOut = Map<String, dynamic>.from(lu);
        luOut['sailor'] = await _lastSailor(pyStr(lu['session']), lu['file'] as String?);
      }
      out.add({
        'puck': int.parse(key.substring(4)),
        'docked': docked,
        'last_seen': seen,
        'last_on_pad': r['last_on_pad'],
        'battery_pct': r.containsKey('battery_mv') ? pctFromMv(r['battery_mv'] as num) : null,
        'battery_mv': r['battery_mv'],
        'charging': docked ? r['charging'] : null,
        'free_kb': r['free_kb'],
        'total_kb': r['total_kb'],
        'fw': r['fw'],
        'pending': r['pending'],
        'rssi': r['rssi'],
        'last_upload': luOut,
      });
    }
    return {'pucks': out, 'now': now};
  }

  Future<int> dayCount() async => (await _days()).length;
}
