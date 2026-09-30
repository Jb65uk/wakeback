// Session storage + all the dock's rules, ported line for line from server/app.py
// so the phone files, cleans and reports things exactly like the dock Pi.
//
// Layout (same as the dock):  <data>/sessions/<YYYY-MM-DD>_<venue>/<puckN_HHMMSS.csv | *.gpx | races.json | meta.json | crew.json | owners.json>
//                             <data>/pucks.json, <data>/venues.json
// A session is a sailing date + venue. Each track has an owner (whose puck/phone sent it) as well as a
// sailor (who was in the boat, crew.json).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'stats.dart';

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

/// Wind for the day from Open-Meteo: {src, lat, lon, got, pts: [[t_ms, dir, kn, gust|null], ...]} (app.py clean_weather).
Map<String, dynamic>? cleanWeather(Object? w) {
  if (w is! Map) return null;
  final pts = <List<Object?>>[];
  final raw = w['pts'];
  if (raw is List) {
    for (final p in raw.take(2000)) {
      try {
        if (p is! List) continue;
        final t = pyInt(p[0]), d = pyFloat(p[1]) % 360, s = pyFloat(p[2]);
        final g = p.length > 3 && p[3] != null ? pyFloat(p[3]) : null;
        if (s >= 0 && s <= 200 && (g == null || (g >= 0 && g <= 250))) pts.add([t, d, s, g]);
      } catch (_) {}
    }
  }
  if (pts.isEmpty) return null;
  final out = <String, dynamic>{'src': cut(pyStr(w.containsKey('src') ? w['src'] : ''), 40), 'pts': pts};
  try {
    final lat = pyFloat(w['lat']), lon = pyFloat(w['lon']);
    if (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
      out['lat'] = lat;
      out['lon'] = lon;
    }
  } catch (_) {}
  try {
    out['got'] = pyInt(w['got']);
  } catch (_) {}
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

// ------------------------------------------------------------------ venues (app.py)

const String unknownVenue = 'unknown';
final List<Map<String, dynamic>> defaultVenues = [
  {'id': 'southport-sc', 'name': 'Southport SC (Marine Lake)', 'lat': 53.6503, 'lon': -3.0102, 'radius_m': 1500, 'auto': false},
];
final RegExp sessionRe = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:_([a-z0-9-]+))?$');

double havM(double la1, double lo1, double la2, double lo2) {
  double r(double d) => d * math.pi / 180;
  final h = math.pow(math.sin(r(la2 - la1) / 2), 2) + math.cos(r(la1)) * math.cos(r(la2)) * math.pow(math.sin(r(lo2 - lo1) / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h));
}

String slug(String name) {
  var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'-+'), '-');
  s = s.replaceAll(RegExp(r'^-+|-+$'), '');
  s = cut(s, 30);
  return s.isEmpty ? 'venue' : s;
}

String autoVenueId(double lat, double lon) {
  String f(double v) => v.abs().toStringAsFixed(2).replaceAll('.', '');
  return 'near-${f(lat)}${lat >= 0 ? 'n' : 's'}-${f(lon)}${lon >= 0 ? 'e' : 'w'}';
}

/// (lat, lon) of the first position in a CSV or GPX, to work out the venue.
List<double>? firstFix(Uint8List bytes, String name) {
  try {
    final head = latin1.decode(bytes.length > 6000 ? bytes.sublist(0, 6000) : bytes);
    if (name.toLowerCase().endsWith('.gpx')) {
      final m = RegExp(r'<trkpt\b([^>]*)>').firstMatch(head);
      if (m == null) return null;
      final la = RegExp(r'\blat="([-0-9.]+)"').firstMatch(m.group(1)!), lo = RegExp(r'\blon="([-0-9.]+)"').firstMatch(m.group(1)!);
      return la != null && lo != null ? [double.parse(la.group(1)!), double.parse(lo.group(1)!)] : null;
    }
    final lines = const LineSplitter().convert(head);
    final cols = lines[0].split(',').map((c) => c.trim().toLowerCase()).toList();
    final ila = cols.indexOf('lat'), ilo = cols.indexOf('lon');
    if (ila < 0 || ilo < 0) return null;
    for (final ln in lines.skip(1)) {
      final c = ln.split(',');
      final lat = ila < c.length ? double.tryParse(c[ila]) : null, lon = ilo < c.length ? double.tryParse(c[ilo]) : null;
      if (lat == null || lon == null) continue;
      if (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 && !(lat == 0 && lon == 0)) return [lat, lon];
    }
  } catch (_) {}
  return null;
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
  File get _venuesFile => File('${data.path}/venues.json');

  /// Who owns tracks this dock records when the puck has no owner of its own. On a phone that's you
  /// (a person, so your boat gets your name); on a club dock it's the club (WAKEBACK_OWNER).
  String ownerName = '';
  String ownerEmail = '';
  bool ownerIsPerson = true;
  Directory dayDir(String day) => Directory('${sessionsDir.path}/$day');

  /// How many pucks the club has, so ones never seen still get a row (WAKEBACK_FLEET).
  int fleet = 0;

  Future<void> init() async {
    await sessionsDir.create(recursive: true);
    await locked(migrateDateFolders);
  }

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
    final vs = await venues();
    final out = <Map<String, dynamic>>[];
    for (final day in days) {
      final files = await trackFiles(day);
      if (files.isEmpty) continue;
      var races = 0;
      final r = await _readJson(File('${dayDir(day).path}/races.json'));
      if (r is List) races = r.length;
      final m = sessionRe.firstMatch(day);
      final vid = m?.group(2) ?? unknownVenue;
      final ow = await _readJson(File('${dayDir(day).path}/owners.json'));
      final owners = <String, dynamic>{}, sharing = <String, dynamic>{}, boats = <String, dynamic>{};
      final mine = <String>[];
      final myEmail = ownerEmail.toLowerCase(), myName = ownerName;
      for (final f in files) {
        final o = ow is Map ? ow[f] : null;
        if (o is Map) {
          owners[f] = pyStr(o['name'] ?? ''); // names only: emails stay here
          sharing[f] = pyStr(o['visibility'] ?? 'friends');
          if (pyStr(o['boat'] ?? '').isNotEmpty) boats[f] = pyStr(o['boat']);
          final e = pyStr(o['email'] ?? '').toLowerCase();
          // mine: my account's, or (no email known) my name's, or nobody's; never one that came down from the server
          if (o['remote'] != true && (e.isEmpty ? (owners[f] == myName || owners[f] == '') : e == myEmail)) mine.add(f);
        } else {
          mine.add(f);
        }
      }
      out.add({
        'id': day, 'date': m?.group(1) ?? cut(day, 10), 'venue': vid, 'venue_name': venueName(vid, vs), 'venue_new': venueIsNew(vid, vs),
        'files': files, 'count': files.length, 'races': races, 'owners': owners, 'sharing': sharing, if (boats.isNotEmpty) 'boats': boats, 'mine': mine,
        'stats': await sessionStats(dayDir(day), files),
      });
    }
    // newest date first, then venue name (sorted(key=(date, venue_name), reverse=True))
    out.sort((a, b) {
      final c = (b['date'] as String).compareTo(a['date'] as String);
      return c != 0 ? c : (b['venue_name'] as String).compareTo(a['venue_name'] as String);
    });
    return out;
  }

  /// Is this track mine (app.py: my email, or my name / nobody's when no email is known; never one from the server)?
  bool _isMine(Object? o) {
    if (o is! Map) return true;
    if (o['remote'] == true) return false;
    final e = pyStr(o['email'] ?? '').toLowerCase(), n = pyStr(o['name'] ?? '');
    return e.isEmpty ? (n == ownerName || n.isEmpty) : e == ownerEmail.toLowerCase();
  }

  /// Every track on this phone as a row with its owner, newest first (app.py _rows_for).
  Future<List<StatRow>> rowsFor(String period) async {
    final since = periodStart(period);
    final vs = await venues();
    final rows = <StatRow>[];
    for (final day in await _days()) {
      final m = sessionRe.firstMatch(day);
      if (m == null) continue;
      final files = await trackFiles(day);
      if (files.isEmpty) continue;
      final st = await sessionStats(dayDir(day), files);
      final ow = await _readJson(File('${dayDir(day).path}/owners.json'));
      final vid = m.group(2) ?? unknownVenue;
      for (final f in files) {
        final s = st[f];
        if (s is! Map || (s['start_ms'] as num) < since) continue;
        final o = ow is Map ? ow[f] : null;
        // a track nobody has claimed on this phone is yours (recorded before you had an account), so the
        // league row and your Stats agree
        final mine = _isMine(o);
        var email = o is Map ? pyStr(o['email'] ?? '').toLowerCase() : '', name = o is Map ? pyStr(o['name'] ?? '') : '';
        if (mine && email.isEmpty) {
          email = ownerEmail.toLowerCase();
          if (name.isEmpty) name = ownerName;
        }
        rows.add(StatRow(day, m.group(1)!, vid, venueName(vid, vs), f, s.cast<String, dynamic>(), ownerEmail: email, ownerName: name, owner: o));
      }
    }
    return rows;
  }

  /// Your own tracks (app.py's rule for "mine"), newest first.
  Future<List<StatRow>> myRows(String period) async => [for (final r in await rowsFor(period)) if (_isMine(r.owner)) r];

  // ---- GET /api/stats?period=  (your tracks only)
  Future<Map<String, dynamic>> myStats(String period) async => {'period': period, ...summarise(await myRows(period))};

  /// A track's text, for drawing it (share card).
  Future<String> trackText(String day, String name) async => (await trackFile(day, name)).readAsString(encoding: latin1);

  // ---- GET /api/league?period=  (everyone on this phone: you, friends' shared tracks, unowned = Club)
  Future<Map<String, dynamic>> leagueTable(String period) async =>
      {'period': period, 'people': league(await rowsFor(period), myEmail: ownerEmail, myName: ownerName)};

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
  /// The boat you usually sail: goes on your own tracks as they land unless the upload names one.
  String defaultBoat = '';

  Future<Map<String, dynamic>> upload(String filename, Uint8List bytes,
      {String puck = '', String sailor = '', String ownerName = '', String ownerEmail = '', String boat = ''}) async {
    var name = tidyName(filename);
    if (!isTrack(name)) {
      throw const DockError(400, 'That file isn\'t a GPX or CSV track. In your sailing app, look for "Export GPX".');
    }
    if (puck.isNotEmpty && !name.toLowerCase().startsWith(puck.toLowerCase())) name = '${puck}_$name';
    final date = firstDay(bytes, name) ?? dayOf(DateTime.now().toUtc());
    var oName = cut(ownerName.trim(), 40), oEmail = cut(ownerEmail.trim(), 120);
    return locked(() async {
      final vid = await _venueFor(firstFix(bytes, name));
      final day = '${date}_$vid';
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
      final pk = pm != null ? 'puck${int.parse(pm.group(1)!)}' : null;
      if (pk != null) {
        final m = await _loadPucks();
        final r = (m[pk] as Map<String, dynamic>?) ?? <String, dynamic>{};
        r['last_upload'] = {'time': DateTime.now().millisecondsSinceEpoch, 'session': day, 'file': fname, 'bytes': bytes.length};
        m[pk] = r;
        await _writeJson(_pucksFile, m);
        final po = r['owner'];
        if (oName.isEmpty && po is Map) {
          oName = pyStr(po['name'] ?? '');
          oEmail = pyStr(po['email'] ?? '');
        }
      }
      var person = true;
      if (oName.isEmpty && this.ownerName.isNotEmpty) {
        oName = this.ownerName;
        oEmail = this.ownerEmail;
        person = ownerIsPerson;
      }
      // owner: whose puck/phone sent it (can edit/delete it later). Sailor: who was in the boat (crew).
      if (oName.isNotEmpty) {
        final of = File('${dir.path}/owners.json');
        final j = await _readJson(of);
        final owners = j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
        var b = cut(boat.trim(), 40);
        if (b.isEmpty && person && oName == this.ownerName) b = defaultBoat; // my own track: my usual boat
        owners[fname] = {'name': oName, if (oEmail.isNotEmpty) 'email': oEmail, 'visibility': 'friends', if (b.isNotEmpty) 'boat': b};
        await _writeJson(of, owners);
        if (person) {
          // the owner's own track: name the boat after them unless someone's said otherwise
          final cf = File('${dir.path}/crew.json');
          final cj = await _readJson(cf);
          final crew = cj is Map ? cj.cast<String, dynamic>() : <String, dynamic>{};
          final key = pk ?? fname;
          if (!pyTruthy(crew[key])) {
            crew[key] = oName;
            await _writeJson(cf, crew);
          }
        }
      }
      final who = cut(sailor.trim(), 40);
      if (who.isNotEmpty) {
        final cf = File('${dir.path}/crew.json');
        final j = await _readJson(cf);
        final crew = j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
        crew[fname] = who;
        await _writeJson(cf, crew);
      }
      return {'ok': true, 'session': day, 'file': fname, 'venue': vid, 'venue_name': venueName(vid, await venues())};
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
      // the owner record follows the track
      final of = File('${dayDir(day).path}/owners.json');
      final j = await _readJson(of);
      if (j is Map && j.containsKey(name)) {
        final rec = j.remove(name);
        await _writeJson(of, j);
        final tf = File('${dayDir(toDay).path}/owners.json');
        final tj = await _readJson(tf);
        final to = tj is Map ? tj.cast<String, dynamic>() : <String, dynamic>{};
        to.putIfAbsent(toName, () => rec);
        await _writeJson(tf, to);
      }
    });
  }

  // ------------------------------------------------------------------ venues

  Future<List<Map<String, dynamic>>> venues() async {
    final j = await _readJson(_venuesFile);
    if (j is List) return j.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    return defaultVenues.map((v) => Map<String, dynamic>.from(v)).toList();
  }

  Future<void> _saveVenues(List<Map<String, dynamic>> vs) => _writeJson(_venuesFile, vs);

  /// Add or replace a venue exactly as given (sync from the server).
  Future<void> upsertVenue(Map<String, dynamic> v) => locked(() async {
        final vs = await venues();
        final i = vs.indexWhere((x) => x['id'] == v['id']);
        if (i < 0) {
          vs.add(v);
        } else {
          vs[i] = v;
        }
        await _saveVenues(vs);
      });

  /// Sharing for one of your tracks: {visibility: friends|private}. Kept in owners.json; sync sends it up.
  Future<Map<String, dynamic>> trackSettings(String day, String file, Object? body) async {
    if (!safeName.hasMatch(day) || !safeName.hasMatch(file)) throw const DockError(400, 'bad name');
    if (!await File('${dayDir(day).path}/$file').exists()) throw const DockError(404, 'not found');
    final vis = body is Map ? body['visibility'] : null;
    final hasBoat = body is Map && body.containsKey('boat');
    if (vis != 'friends' && vis != 'private' && !hasBoat) throw const DockError(400, 'nothing to change');
    return locked(() async {
      final f = File('${dayDir(day).path}/owners.json');
      final j = await _readJson(f);
      final m = j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
      final o = m[file] is Map ? (m[file] as Map).cast<String, dynamic>() : <String, dynamic>{'name': ownerName, if (ownerEmail.isNotEmpty) 'email': ownerEmail};
      if (vis == 'friends' || vis == 'private') o['visibility'] = vis;
      if (hasBoat) {
        final b = cut(pyStr(body['boat'] ?? '').trim(), 40);
        if (b.isEmpty) {
          o.remove('boat');
        } else {
          o['boat'] = b;
        }
      }
      o.putIfAbsent('visibility', () => 'friends');
      m[file] = o;
      await _writeJson(f, m);
      return {'name': pyStr(o['name'] ?? ''), 'visibility': pyStr(o['visibility']), if (pyStr(o['boat'] ?? '').isNotEmpty) 'boat': pyStr(o['boat'])};
    });
  }

  /// Record who sent a track (sync: a mate's track downloaded from the server keeps their name).
  Future<void> setOwner(String day, String file, Map<String, dynamic> owner) => locked(() async {
        final f = File('${dayDir(day).path}/owners.json');
        final j = await _readJson(f);
        final m = j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};
        m[file] = owner;
        await _writeJson(f, m);
      });

  /// {name, email} of whoever sent this track, if known.
  Future<Map<String, dynamic>?> ownerOf(String day, String file) async {
    final j = await _readJson(File('${dayDir(day).path}/owners.json'));
    final o = j is Map ? j[file] : null;
    return o is Map ? o.cast<String, dynamic>() : null;
  }

  static String venueName(String vid, List<Map<String, dynamic>> vs) {
    if (vid == unknownVenue) return 'Unknown venue';
    for (final v in vs) {
      if (v['id'] == vid) return pyStr(v['name']);
    }
    return vid;
  }

  static bool venueIsNew(String vid, List<Map<String, dynamic>> vs) =>
      vid == unknownVenue || vs.any((v) => v['id'] == vid && v['auto'] == true);

  /// Venue id for a position, adding an automatic venue if it's somewhere new. Call inside `locked`.
  Future<String> _venueFor(List<double>? pos) async {
    if (pos == null) return unknownVenue;
    final vs = await venues();
    Map<String, dynamic>? best;
    var bestD = double.infinity;
    for (final v in vs) {
      if (v['lat'] is! num || v['lon'] is! num) continue;
      final d = havM(pos[0], pos[1], (v['lat'] as num).toDouble(), (v['lon'] as num).toDouble());
      if (d < bestD) {
        bestD = d;
        best = v;
      }
    }
    if (best != null && bestD <= ((best['radius_m'] as num?) ?? 1500)) return '${best['id']}';
    final vid = autoVenueId(pos[0], pos[1]);
    if (!vs.any((v) => v['id'] == vid)) {
      vs.add({
        'id': vid, 'name': 'New venue near ${pos[0].toStringAsFixed(2)}, ${pos[1].toStringAsFixed(2)}',
        'lat': double.parse(pos[0].toStringAsFixed(4)), 'lon': double.parse(pos[1].toStringAsFixed(4)), 'radius_m': 1500, 'auto': true,
      });
      await _saveVenues(vs);
    }
    return vid;
  }

  Map<String, dynamic> _cleanVenue(Map b, Map<String, dynamic> old) {
    final v = Map<String, dynamic>.from(old);
    if (b.containsKey('name')) {
      final n = cut(pyStr(b['name']).trim(), 60);
      if (n.isEmpty) throw const DockError(400, 'a venue needs a name');
      v['name'] = n;
      v['auto'] = false;
    }
    for (final (k, lo, hi) in [('lat', -90.0, 90.0), ('lon', -180.0, 180.0), ('radius_m', 100.0, 20000.0)]) {
      if (!b.containsKey(k)) continue;
      double x;
      try {
        x = pyFloat(b[k]);
      } catch (_) {
        throw DockError(400, 'bad $k');
      }
      if (x < lo || x > hi) throw DockError(400, '$k out of range');
      v[k] = k == 'radius_m' ? x.truncate() : double.parse(x.toStringAsFixed(5));
    }
    return v;
  }

  // ---- POST /api/venues (returns [status, venue])
  Future<(int, Map<String, dynamic>)> addVenue(Object? body) async {
    if (body is! Map || !pyTruthy(body['name']) || !body.containsKey('lat') || !body.containsKey('lon')) {
      throw const DockError(400, 'name, lat and lon needed');
    }
    return locked(() async {
      final vs = await venues();
      final want = pyStr(body['id'] ?? '');
      final ok = RegExp(r'^[a-z0-9-]{1,40}$').hasMatch(want);
      if (want.isNotEmpty && ok) {
        for (final v in vs) {
          if (v['id'] == want) return (200, v); // already here (sync sends it again)
        }
      }
      var vid = ok ? want : slug(pyStr(body['name']));
      final base = vid;
      var n = 1;
      while (vs.any((v) => v['id'] == vid) || vid == unknownVenue) {
        n++;
        vid = '$base-$n';
      }
      final v = _cleanVenue(body, {'id': vid, 'radius_m': 1500});
      v['auto'] = pyTruthy(body['auto'] ?? false);
      vs.add(v);
      await _saveVenues(vs);
      return (201, v);
    });
  }

  // ---- PUT /api/venues/<id>
  Future<Map<String, dynamic>> putVenue(String vid, Object? body) async {
    if (body is! Map) throw const DockError(400, 'expected an object');
    return locked(() async {
      final vs = await venues();
      final i = vs.indexWhere((v) => v['id'] == vid);
      if (i < 0) throw const DockError(404, 'not found');
      vs[i] = _cleanVenue(body, vs[i]);
      await _saveVenues(vs);
      return vs[i];
    });
  }

  // ---- POST /api/sessions/<id>/move  (wrong venue: move the session, merging if needed)
  Future<String> moveSession(String day, Object? body) async {
    if (!safeName.hasMatch(day)) throw const DockError(400, 'bad day');
    final vid = pyStr(body is Map ? (body['venue'] ?? '') : '');
    final m = sessionRe.firstMatch(day);
    if (m == null || !await dayDir(day).exists()) throw const DockError(404, 'not found');
    if (vid != unknownVenue && !(await venues()).any((v) => v['id'] == vid)) throw const DockError(400, 'no such venue');
    final to = '${m.group(1)}_$vid';
    if (to == day) return day;
    await locked(() async {
      final src = dayDir(day), dst = dayDir(to);
      await dst.create(recursive: true);
      final entries = await src.list().toList(); // list first: we rename as we go
      for (final e in entries) {
        if (e is! File) continue;
        final f = baseName(e.path);
        var target = File('${dst.path}/$f');
        if (f.endsWith('.json')) {
          if ((f == 'crew.json' || f == 'owners.json') && await target.exists()) {
            final a = await _readJson(e), b = await _readJson(target);
            await _writeJson(target, {if (a is Map) ...a, if (b is Map) ...b});
            await e.delete();
          } else if (await target.exists()) {
            await e.delete();
          } else {
            await e.rename(target.path);
          }
          continue;
        }
        final dot = f.lastIndexOf('.');
        final base = dot > 0 ? f.substring(0, dot) : f, ext = dot > 0 ? f.substring(dot) : '';
        var n = 1;
        while (await target.exists()) {
          n++;
          target = File('${dst.path}/$base-$n$ext');
        }
        await e.rename(target.path);
      }
      await src.delete(recursive: true);
    });
    return to;
  }

  /// Older layouts filed sessions by date only ("2026-09-20"). Split each into date + venue folders.
  Future<int> migrateDateFolders() async {
    final moved = <String, String>{}; // "day|file" -> new session
    final days = await _days();
    days.sort();
    for (final day in days) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) continue;
      final src = dayDir(day);
      final groups = <String, List<File>>{};
      for (final e in await src.list().toList()) {
        if (e is File && isTrack(baseName(e.path))) {
          final vid = await _venueFor(firstFix(await e.readAsBytes(), baseName(e.path)));
          groups.putIfAbsent(vid, () => []).add(e);
        }
      }
      for (final g in groups.entries) {
        final dst = dayDir('${day}_${g.key}');
        await dst.create(recursive: true);
        for (final f in g.value) {
          await f.rename('${dst.path}/${baseName(f.path)}');
          moved['$day|${baseName(f.path)}'] = '${day}_${g.key}';
        }
        for (final j in ['races.json', 'meta.json', 'crew.json', 'owners.json']) {
          final a = File('${src.path}/$j'), b = File('${dst.path}/$j');
          if (await a.exists() && !await b.exists()) await a.copy(b.path);
        }
      }
      await src.delete(recursive: true);
    }
    if (moved.isNotEmpty) {
      final m = await _loadPucks();
      for (final r in m.values) {
        final lu = r is Map ? r['last_upload'] : null;
        if (lu is Map) {
          final k = '${lu['session']}|${lu['file']}';
          if (moved.containsKey(k)) lu['session'] = moved[k];
        }
      }
      await _writeJson(_pucksFile, m);
    }
    return moved.length;
  }

  // ---- DELETE /api/sessions/<day>/<name>
  Future<void> deleteTrack(String day, String name) async {
    final f = await trackFile(day, name);
    await f.delete();
  }

  /// Remove a whole session from this phone (tracks, course, crew, stats).
  Future<void> deleteSession(String day) => locked(() async {
        _checkDay(day);
        final d = dayDir(day);
        if (await d.exists()) await d.delete(recursive: true);
      });

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
    final wx = cleanWeather(body['weather']);
    if (wx != null) clean['weather'] = wx;
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
