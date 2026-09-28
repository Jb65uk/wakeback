// Track statistics, ported from server/stats.py so the phone shows the same numbers as the server:
// distance while moving (> 0.5 kn), top speed = 99.5th percentile, average while > 1 kn, time on the
// water = samples over 1.5 kn, all on speed smoothed over ±1 s like the viewer's boat list.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const double kKn = 1.943844;
const int kCacheV = 2; // bump when computeStats learns something new, so old stats.json files are redone

double _havM(double la1, double lo1, double la2, double lo2) {
  double r(double d) => d * (math.pi / 180); // exactly math.radians()
  final h = math.pow(math.sin(r(la2 - la1) / 2), 2) + math.cos(r(la1)) * math.cos(r(la2)) * math.pow(math.sin(r(lo2 - lo1) / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h.clamp(0.0, 1.0).toDouble()));
}

/// Python's round(x, n) (to the nearest representable; ties are vanishingly rare on real data).
double roundTo(double x, int n) => double.parse(x.toStringAsFixed(n));

class _Pt {
  final int t;
  final double lat, lon;
  final double? sog, hdg, heel;
  const _Pt(this.t, this.lat, this.lon, this.sog, [this.hdg, this.heel]);
}

double _bearing(double la1, double lo1, double la2, double lo2) {
  double r(double d) => d * (math.pi / 180);
  final y = math.sin(r(lo2 - lo1)) * math.cos(r(la2));
  final x = math.cos(r(la1)) * math.sin(r(la2)) - math.sin(r(la1)) * math.cos(r(la2)) * math.cos(r(lo2 - lo1));
  return (math.atan2(y, x) * (180 / math.pi) + 360) % 360;
}

/// (dir_from_deg, speed_kn) from the day's hourly weather (meta.weather), nearest hour, or null.
(double, double)? windAt(Map? weather, int tMs) {
  final pts = weather?['pts'];
  if (pts is! List || pts.isEmpty) return null;
  List? best;
  var bd = 1 << 62;
  for (final p in pts) {
    if (p is! List || p.length < 3) continue;
    final d = ((p[0] as num).toInt() - tMs).abs();
    if (d < bd) {
      bd = d;
      best = p;
    }
  }
  if (best == null || bd > 2 * 3600 * 1000) return null;
  return ((best[1] as num).toDouble(), (best[2] as num).toDouble());
}

/// The positions of a track, for drawing it: [[lat, lon], ...] in time order.
List<List<double>> trackPositions(String text, String name) => [for (final p in _points(text, name)) [p.lat, p.lon]];

int? _parseTime(String s) {
  try {
    return DateTime.parse(s.trim()).toUtc().millisecondsSinceEpoch;
  } catch (_) {
    return null;
  }
}

List<_Pt> _points(String text, String name) {
  final pts = <_Pt>[];
  if (name.toLowerCase().endsWith('.gpx')) {
    final trk = RegExp(r'<trkpt\b([^>]*)>(.*?)</trkpt>', dotAll: true);
    final latRe = RegExp(r'\blat="([-0-9.]+)"'), lonRe = RegExp(r'\blon="([-0-9.]+)"');
    final timeRe = RegExp(r'<time>([^<]+)</time>'), spRe = RegExp(r'<(?:gpxtpx:)?speed>([-0-9.eE]+)</');
    for (final m in trk.allMatches(text)) {
      final la = latRe.firstMatch(m.group(1)!), lo = lonRe.firstMatch(m.group(1)!), tm = timeRe.firstMatch(m.group(2)!);
      if (la == null || lo == null || tm == null) continue;
      final t = _parseTime(tm.group(1)!);
      if (t == null) continue;
      final sp = spRe.firstMatch(m.group(2)!);
      final lat = double.tryParse(la.group(1)!), lon = double.tryParse(lo.group(1)!);
      if (lat == null || lon == null) continue;
      pts.add(_Pt(t, lat, lon, sp == null ? null : double.parse(sp.group(1)!) * kKn));
    }
  } else {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return [];
    final cols = lines[0].split(',').map((c) => c.trim().toLowerCase()).toList();
    final it = cols.indexOf('t_ms'), ila = cols.indexOf('lat'), ilo = cols.indexOf('lon'), isog = cols.indexOf('sog_kn');
    final ihdg = cols.indexOf('hdg'), iheel = cols.indexOf('heel');
    if (it < 0 || ila < 0 || ilo < 0) return [];
    double? opt(List<String> c, int i) => i >= 0 && i < c.length && c[i].isNotEmpty ? double.tryParse(c[i]) : null;
    for (final ln in lines.skip(1)) {
      final c = ln.split(',');
      try {
        var t = double.parse(c[it]);
        final lat = double.parse(c[ila]), lon = double.parse(c[ilo]);
        if (t < 1e12) t *= 1000;
        final sog = isog >= 0 && isog < c.length && c[isog].isNotEmpty ? double.parse(c[isog]) : null;
        if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)) continue;
        pts.add(_Pt(t.toInt(), lat, lon, sog, opt(c, ihdg), opt(c, iheel)));
      } catch (_) {
        continue;
      }
    }
  }
  pts.sort((a, b) => a.t.compareTo(b.t));
  return pts;
}

/// Stats for one track's text, or null if it has no usable positions. With the day's weather (meta.weather):
/// upwind/downwind averages, best VMG and the wind strength it was sailed in.
Map<String, dynamic>? computeStats(String text, String name, [Map? weather]) {
  final pts = _points(text, name);
  if (pts.length < 2) return null;
  final n = pts.length;
  var sog = List<double>.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    final p = pts[i];
    if (p.sog != null) {
      sog[i] = p.sog!;
    } else if (i > 0) {
      final dt = (p.t - pts[i - 1].t) / 1000;
      sog[i] = dt > 0 ? _havM(pts[i - 1].lat, pts[i - 1].lon, p.lat, p.lon) / dt * kKn : 0.0;
    }
  }
  // smooth over ±1 s (at least the neighbours)
  final pre = List<double>.filled(n + 1, 0.0);
  for (var i = 0; i < n; i++) {
    pre[i + 1] = pre[i] + sog[i];
  }
  final sm = List<double>.filled(n, 0.0);
  var a = 0, b = 0;
  for (var i = 0; i < n; i++) {
    while (pts[i].t - pts[a].t > 1000) {
      a++;
    }
    while (b + 1 < n && pts[b + 1].t - pts[i].t <= 1000) {
      b++;
    }
    final lo = math.min(a, math.max(0, i - 1)), hi = math.max(b, math.min(n - 1, i + 1));
    sm[i] = (pre[hi + 1] - pre[lo]) / (hi - lo + 1);
  }
  sog = sm;
  var dist = 0.0, sSum = 0.0;
  var movingMs = 0, sCnt = 0;
  for (var i = 1; i < n; i++) {
    final d = _havM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    final dt = pts[i].t - pts[i - 1].t;
    if (dt <= 0 || dt > 60000) continue;
    if (d / (dt / 1000) > 40) continue;
    if (sog[i] > 0.5) dist += d;
    if (sog[i] > 1) {
      sSum += sog[i];
      sCnt++;
    }
    if (sog[i] > 1.5) movingMs += dt;
  }
  final vals = List<double>.of(sog)..sort();
  final out = <String, dynamic>{
    'points': n, 'start_ms': pts.first.t, 'end_ms': pts.last.t,
    'dist_nm': roundTo(dist / 1852, 3),
    'max_kn': roundTo(vals[math.min(vals.length - 1, (vals.length * 0.995).toInt())], 2),
    'avg_kn': sCnt > 0 ? roundTo(sSum / sCnt, 2) : 0.0,
    'moving_s': movingMs ~/ 1000,
  };
  // heel (pucks only): 99th percentile of |heel|, and capsizes = |heel| > 80 deg for 10 s or more
  final heels = [for (final p in pts) if (p.heel != null) p.heel!.abs()]..sort();
  if (heels.isNotEmpty) {
    out['max_heel'] = roundTo(heels[math.min(heels.length - 1, (heels.length * 0.99).toInt())], 1);
    var caps = 0;
    int? runStart;
    var over = false;
    for (final p in pts) {
      if (p.heel != null && p.heel!.abs() > 80) {
        if (runStart == null) {
          runStart = p.t;
          over = false;
        }
        if (!over && p.t - runStart >= 10000) {
          caps++;
          over = true;
        }
      } else {
        runStart = null;
      }
    }
    out['capsizes'] = caps;
  }
  // the wind: heading vs the hour's wind direction while moving
  if (weather != null) {
    final up = <double>[], down = <double>[], wkn = <double>[];
    final vmg = <(int, double)>[];
    for (var i = 1; i < n; i++) {
      if (sog[i] <= 1) continue;
      final w = windAt(weather, pts[i].t);
      if (w == null) continue;
      var hdg = pts[i].hdg;
      if (hdg == null) {
        if (pts[i].t - pts[i - 1].t <= 0) continue;
        hdg = _bearing(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
      }
      final ang = ((hdg - w.$1 + 180) % 360 - 180).abs(); // 0 = straight into the wind
      wkn.add(w.$2);
      if (ang < 60) {
        up.add(sog[i]);
        vmg.add((pts[i].t, sog[i] * math.cos(ang * (math.pi / 180))));
      } else if (ang > 120) {
        down.add(sog[i]);
      }
    }
    if (wkn.isNotEmpty) {
      out['wind_kn'] = roundTo(wkn.reduce((a, b) => a + b) / wkn.length, 1);
      if (up.isNotEmpty) out['up_kn'] = roundTo(up.reduce((a, b) => a + b) / up.length, 2);
      if (down.isNotEmpty) out['down_kn'] = roundTo(down.reduce((a, b) => a + b) / down.length, 2);
      var best = 0.0, acc = 0.0;
      var a = 0;
      for (var b = 0; b < vmg.length; b++) {
        acc += vmg[b].$2;
        while (vmg[b].$1 - vmg[a].$1 > 30000) {
          acc -= vmg[a].$2;
          a++;
        }
        if (vmg[b].$1 - vmg[a].$1 >= 20000) best = math.max(best, acc / (b - a + 1));
      }
      if (best > 0) out['vmg_kn'] = roundTo(best, 2);
    }
  }
  return out;
}

/// {file: stats} for a session folder, cached in stats.json (redone when a file's size changes).
Future<Map<String, dynamic>> sessionStats(Directory folder, List<String> files) async {
  final cf = File('${folder.path}/stats.json');
  Map<String, dynamic> cache = {};
  try {
    final j = jsonDecode(await cf.readAsString());
    if (j is Map) cache = j.cast<String, dynamic>();
  } catch (_) {}
  Map? weather;
  try {
    final m = jsonDecode(await File('${folder.path}/meta.json').readAsString());
    if (m is Map && m['weather'] is Map) weather = m['weather'] as Map;
  } catch (_) {}
  final wxKey = weather == null ? 0 : (weather['got'] ?? 1);
  final out = <String, dynamic>{};
  var changed = false;
  for (final fn in files) {
    final f = File('${folder.path}/$fn');
    int size;
    try {
      size = await f.length();
    } catch (_) {
      continue;
    }
    final c = cache[fn];
    if (c is Map && c['_size'] == size && (c['_wx'] ?? 0) == wxKey && c['_v'] == kCacheV) {
      if (c['_none'] != true) out[fn] = {for (final e in c.entries) if (!e.key.toString().startsWith('_')) e.key.toString(): e.value};
      continue;
    }
    Map<String, dynamic>? st;
    try {
      st = computeStats(await f.readAsString(encoding: latin1), fn, weather);
    } catch (_) {
      st = null;
    }
    cache[fn] = {...?st, '_size': size, '_wx': wxKey, '_v': kCacheV, '_none': st == null};
    changed = true;
    if (st != null) out[fn] = st;
  }
  if (changed) {
    try {
      final tmp = File('${cf.path}.tmp');
      await tmp.writeAsString(jsonEncode({for (final e in cache.entries) if (files.contains(e.key)) e.key: e.value}), flush: true);
      await tmp.rename(cf.path);
    } catch (_) {}
  }
  return out;
}

String _month(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
}

/// 'month' / 'year' / anything else = all time → start in ms (UTC).
int periodStart(String period, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toUtc();
  if (period == 'month') return DateTime.utc(n.year, n.month, 1).millisecondsSinceEpoch;
  if (period == 'year') return DateTime.utc(n.year, 1, 1).millisecondsSinceEpoch;
  return 0;
}

/// A track with where it lives and whose it is; the unit of stats and the league.
class StatRow {
  final String session, date, venue, venueName, file, ownerEmail, ownerName;
  final Map<String, dynamic> stats;
  /// the raw owners.json entry (null when nobody has claimed it)
  final Object? owner;
  const StatRow(this.session, this.date, this.venue, this.venueName, this.file, this.stats, {this.ownerEmail = '', this.ownerName = '', this.owner});
  double get distNm => (stats['dist_nm'] as num).toDouble();
  double get maxKn => (stats['max_kn'] as num).toDouble();
  double get avgKn => (stats['avg_kn'] as num).toDouble();
  int get movingS => (stats['moving_s'] as num).toInt();
  int get startMs => (stats['start_ms'] as num).toInt();
  Map<String, dynamic> get ref => {'session': session, 'file': file, 'date': date, 'venue_name': venueName};
}

const windBins = ['0-5', '5-10', '10-15', '15-20', '20+'];
String windBin(double kn) => kn < 5 ? '0-5' : kn < 10 ? '5-10' : kn < 15 ? '10-15' : kn < 20 ? '15-20' : '20+';

/// Totals for one person's rows (stats.py summarise).
Map<String, dynamic> summarise(List<StatRow> rows) {
  if (rows.isEmpty) {
    return {'sessions': 0, 'tracks': 0, 'dist_nm': 0.0, 'moving_h': 0.0, 'max_kn': 0.0, 'avg_kn': 0.0, 'best_avg_kn': 0.0};
  }
  final sessions = rows.map((r) => r.session).toSet();
  var dist = 0.0, w = 0.0;
  var moving = 0;
  for (final r in rows) {
    dist += r.distNm;
    moving += r.movingS;
    w += r.avgKn * r.movingS;
  }
  StatRow best(double Function(StatRow) key) {
    var b = rows.first;
    for (final r in rows.skip(1)) {
      if (key(r) > key(b)) b = r; // first wins ties, like Python's max
    }
    return b;
  }
  final fastest = best((r) => r.maxKn), bestAvg = best((r) => r.avgKn), longest = best((r) => r.distNm);
  final venues = <String, int>{};
  for (final r in rows) {
    venues[r.venueName] = (venues[r.venueName] ?? 0) + 1;
  }
  String? fav;
  var favN = -1;
  for (final e in venues.entries) {
    if (e.value > favN) {
      fav = e.key;
      favN = e.value;
    }
  }
  final byMonth = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    final k = _month(r.startMs);
    final m = byMonth.putIfAbsent(k, () => {'month': k, 'dist_nm': 0.0, 'sessions': <String>{}, 'moving_s': 0});
    m['dist_nm'] = (m['dist_nm'] as double) + r.distNm;
    (m['sessions'] as Set<String>).add(r.session);
    m['moving_s'] = (m['moving_s'] as int) + r.movingS;
  }
  final months = byMonth.values
      .map((m) => {'month': m['month'], 'dist_nm': roundTo(m['dist_nm'] as double, 2), 'sessions': (m['sessions'] as Set).length, 'moving_s': m['moving_s']})
      .toList()
    ..sort((a, b) => (a['month'] as String).compareTo(b['month'] as String));
  final dates = rows.map((r) => r.date).toList()..sort();
  // the wind: sessions grouped by strength, and upwind / downwind / VMG bests
  final bins = <String, Map<String, dynamic>>{};
  for (final r in rows) {
    final st = r.stats;
    if (!st.containsKey('wind_kn')) continue;
    final k = windBin((st['wind_kn'] as num).toDouble());
    final b = bins.putIfAbsent(k, () => {'bin': k, 'sessions': <String>{}, 'w': 0.0, 'moving_s': 0, 'best_avg_kn': 0.0, 'max_kn': 0.0});
    (b['sessions'] as Set<String>).add(r.session);
    b['w'] = (b['w'] as double) + r.avgKn * r.movingS;
    b['moving_s'] = (b['moving_s'] as int) + r.movingS;
    b['best_avg_kn'] = math.max(b['best_avg_kn'] as double, r.avgKn);
    b['max_kn'] = math.max(b['max_kn'] as double, r.maxKn);
  }
  final wind = (bins.values.toList()..sort((a, b) => windBins.indexOf(a['bin'] as String).compareTo(windBins.indexOf(b['bin'] as String))))
      .map((b) => {
            'bin': b['bin'], 'sessions': (b['sessions'] as Set).length,
            'avg_kn': (b['moving_s'] as int) > 0 ? roundTo((b['w'] as double) / (b['moving_s'] as int), 2) : 0.0,
            'best_avg_kn': b['best_avg_kn'], 'max_kn': b['max_kn'], 'moving_h': roundTo((b['moving_s'] as int) / 3600, 2),
          })
      .toList();
  final extra = <String, dynamic>{};
  for (final key in ['up_kn', 'down_kn', 'vmg_kn', 'max_heel']) {
    StatRow? b;
    for (final r in rows) {
      if (r.stats.containsKey(key) && (b == null || (r.stats[key] as num) > (b.stats[key] as num))) b = r;
    }
    if (b != null) {
      extra[key] = b.stats[key];
      extra['${key.replaceAll('_kn', '').replaceAll('max_', '')}_track'] = b.ref;
    }
  }
  double? weighted(String key) {
    var w = 0.0;
    var m = 0;
    for (final r in rows) {
      if (r.stats.containsKey(key)) {
        w += (r.stats[key] as num) * r.movingS;
        m += r.movingS;
      }
    }
    return m > 0 ? roundTo(w / m, 2) : null;
  }
  final avgUp = weighted('up_kn'), avgDown = weighted('down_kn');
  if (avgUp != null) extra['avg_up_kn'] = avgUp;
  if (avgDown != null) extra['avg_down_kn'] = avgDown;
  var capsizes = 0;
  for (final r in rows) {
    capsizes += ((r.stats['capsizes'] as num?) ?? 0).toInt();
  }
  extra['capsizes'] = capsizes;
  return {
    'wind': wind, ...extra,
    'sessions': sessions.length, 'tracks': rows.length,
    'dist_nm': roundTo(dist, 2), 'moving_h': roundTo(moving / 3600, 2),
    'max_kn': fastest.maxKn, 'max_track': fastest.ref,
    'avg_kn': moving > 0 ? roundTo(w / moving, 2) : 0.0,
    'best_avg_kn': bestAvg.avgKn, 'best_avg_track': bestAvg.ref,
    'longest_nm': longest.distNm, 'longest_track': longest.ref,
    'venues': venues.length, 'favourite_venue': fav,
    'first_date': dates.first, 'last_date': dates.last,
    'by_month': months,
  };
}

/// League rows from everyone's tracks (app.py /api/league): grouped by owner email, else name, else "Club".
List<Map<String, dynamic>> league(List<StatRow> rows, {String myEmail = '', String myName = ''}) {
  final by = <String, List<StatRow>>{};
  final names = <String, String>{};
  for (final r in rows) {
    final key = r.ownerEmail.isNotEmpty ? r.ownerEmail : (r.ownerName.isNotEmpty ? r.ownerName : 'Club');
    by.putIfAbsent(key, () => []).add(r);
    names.putIfAbsent(key, () => r.ownerName.isNotEmpty ? r.ownerName : 'Club'); // first name wins, like the server
  }
  final people = <Map<String, dynamic>>[];
  for (final e in by.entries) {
    final sm = summarise(e.value);
    final me = (myEmail.isNotEmpty && e.key == myEmail.toLowerCase()) || (!e.key.contains('@') && myName.isNotEmpty && e.key == myName);
    people.add({
      'name': names[e.key], 'me': me,
      'sessions': sm['sessions'], 'dist_nm': sm['dist_nm'], 'moving_h': sm['moving_h'], 'max_kn': sm['max_kn'],
      'avg_kn': sm['avg_kn'], 'best_avg_kn': sm['best_avg_kn'], 'longest_nm': sm['longest_nm'] ?? 0,
    });
  }
  people.sort((a, b) => (b['dist_nm'] as num).compareTo(a['dist_nm'] as num));
  return people;
}
