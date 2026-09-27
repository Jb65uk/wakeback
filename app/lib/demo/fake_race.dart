// Port of tools/gen_fake_data.py — same boat model, same 10 Hz puck CSV format.
import 'dart:math' as math;

const double _kn = 1.943844; // m/s -> knots
const double centreLat = 53.6503, centreLon = -3.0102; // Marine Lake, Southport (approximate)

double _rad(double d) => d * math.pi / 180;

class TrackRow {
  final DateTime t;
  final double lat, lon, sog, hdg, heel, pitch;
  const TrackRow(this.t, this.lat, this.lon, this.sog, this.hdg, this.heel, this.pitch);
}

double _mod(double a, double m) => ((a % m) + m) % m;

List<TrackRow> simBoat(double baseKn, int seed, double startOffset, double heelUp,
    {double wind = 25, required DateTime t0, int laps = 3}) {
  final r = math.Random(seed);
  final u = [math.sin(_rad(wind)), math.cos(_rad(wind))];
  final v = [math.cos(_rad(wind)), -math.sin(_rad(wind))];
  List<double> mk(double a, double c) => [u[0] * a + v[0] * c, u[1] * a + v[1] * c];
  final marks = [mk(380, 10), mk(-360, 45), mk(-120, -45)];
  var x = marks[2][0] + startOffset, y = marks[2][1] - 15;
  var side = 1, dside = 1, mi = 0, lap = 0;
  var tackT = -99.0;
  const dt = 0.1;
  var s = 0.0;
  final rows = <TrackRow>[];
  while (s < 3 * 3600 && lap < laps) {
    final tx = marks[mi][0] - x, ty = marks[mi][1] - y;
    final d = math.sqrt(tx * tx + ty * ty);
    if (d < 12) {
      mi = (mi + 1) % 3;
      if (mi == 0) lap++;
      continue;
    }
    final want = _mod(math.atan2(tx, ty) * 180 / math.pi + 360, 360);
    final diff = _mod(want - wind + 540, 360) - 180;
    double hdg, k, heel, pitch;
    if (diff.abs() < 42) {
      // beating; port tack (TWA>0) heels to starboard (+)
      final latOff = x * v[0] + y * v[1];
      if (latOff * side > 60) {
        side = -side;
        tackT = s;
      }
      hdg = wind + side * 42;
      k = 0.82;
      heel = side * heelUp;
      pitch = -1;
    } else if (diff.abs() > 140) {
      // run: sail by the lee-ish angles and gybe down the leg
      final latOff = x * v[0] + y * v[1] - (marks[mi][0] * v[0] + marks[mi][1] * v[1]);
      if (latOff * dside > 35) {
        dside = -dside;
        tackT = s;
      }
      hdg = wind + 180 - dside * 22;
      k = 0.95;
      heel = -dside * heelUp * 0.25;
      pitch = 3;
    } else {
      hdg = want;
      k = 1.15;
      final sgn = diff > 0 ? 1 : -1;
      heel = sgn * heelUp * 0.7;
      pitch = 0.5;
    }
    final since = s - tackT;
    if (since < 8) {
      k *= 0.55 + 0.45 * since / 8;
      heel *= since / 8;
    }
    heel += 2.5 * math.sin(s / 3.1 + seed) + 1.5 * (r.nextDouble() - 0.5);
    pitch += 1.2 * math.sin(s / 2.3 + seed) + 0.8 * (r.nextDouble() - 0.5);
    final kn = baseKn * k * (1 + 0.07 * math.sin(s / 9 + seed) + 0.06 * (r.nextDouble() - 0.5));
    final ms = kn / _kn;
    x += math.sin(_rad(hdg)) * ms * dt;
    y += math.cos(_rad(hdg)) * ms * dt;
    final nx = x + (r.nextDouble() - 0.5) * 1.2, ny = y + (r.nextDouble() - 0.5) * 1.2;
    final lat = centreLat + ny / 111320;
    final lon = centreLon + nx / (111320 * math.cos(_rad(centreLat)));
    rows.add(TrackRow(t0.add(Duration(microseconds: (s * 1e6).round())), lat, lon, kn + 0.05 * (r.nextDouble() - 0.5), _mod(hdg, 360), heel, pitch));
    s += dt;
  }
  return rows;
}

/// A boat drifting slowly between races.
List<TrackRow> drift(List<TrackRow> a, List<TrackRow> b, math.Random r, {double dt = 0.1}) {
  final t0 = a.last.t, lat0 = a.last.lat, lon0 = a.last.lon;
  final t1 = b.first.t, lat1 = b.first.lat, lon1 = b.first.lon;
  final n = (t1.difference(t0).inMicroseconds / 1e6 / dt).floor();
  final rows = <TrackRow>[];
  var hdg = r.nextDouble() * 360;
  for (var k = 1; k < n; k++) {
    final f = k / n;
    hdg = _mod(hdg + (r.nextDouble() - 0.5) * 4, 360);
    rows.add(TrackRow(
      t0.add(Duration(microseconds: (k * dt * 1e6).round())),
      lat0 + (lat1 - lat0) * f + (r.nextDouble() - 0.5) * 2e-5,
      lon0 + (lon1 - lon0) * f + (r.nextDouble() - 0.5) * 3e-5,
      0.3 + 0.5 * r.nextDouble(),
      hdg,
      (r.nextDouble() - 0.5) * 3,
      (r.nextDouble() - 0.5) * 2,
    ));
  }
  return rows;
}

/// Race 1 (3 laps), drift, race 2 (2 laps) — one log file, like a real morning.
List<TrackRow> twoRaces(double baseKn, int seed, double offset, double heel, DateTime t0) {
  final r1 = simBoat(baseKn, seed, offset, heel, t0: t0, laps: 3);
  final start2 = t0.add(const Duration(minutes: 57));
  final r2 = simBoat(baseKn * 0.97, seed + 100, -offset, heel, t0: start2, laps: 2);
  return [...r1, ...drift(r1, r2, math.Random(seed)), ...r2];
}

String toPuckCsv(List<TrackRow> rows) {
  final sb = StringBuffer('t_ms,lat,lon,sog_kn,hdg,heel,pitch\n');
  for (final w in rows) {
    sb
      ..write(w.t.millisecondsSinceEpoch)
      ..write(',')
      ..write(w.lat.toStringAsFixed(7))
      ..write(',')
      ..write(w.lon.toStringAsFixed(7))
      ..write(',')
      ..write(w.sog.toStringAsFixed(2))
      ..write(',')
      ..write(w.hdg.toStringAsFixed(0))
      ..write(',')
      ..write(w.heel.toStringAsFixed(1))
      ..write(',')
      ..write(w.pitch.toStringAsFixed(1))
      ..write('\n');
  }
  return sb.toString();
}

String toGpx(String name, List<TrackRow> rows, {int every = 10}) {
  String iso(DateTime t) => '${t.toUtc().toIso8601String().split('.').first}Z';
  final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="phone" xmlns="http://www.topografix.com/GPX/1/1">\n'
      '<trk><name>$name</name><trkseg>\n');
  for (var i = 0; i < rows.length; i += every) {
    final w = rows[i];
    sb.write('<trkpt lat="${w.lat.toStringAsFixed(6)}" lon="${w.lon.toStringAsFixed(6)}"><time>${iso(w.t)}</time></trkpt>\n');
  }
  sb.write('</trkseg></trk>\n</gpx>\n');
  return sb.toString();
}

/// The course laid for the demo day: marks (all left to starboard) plus start and finish lines.
Map<String, dynamic> demoMeta({double wind = 25}) {
  final u = [math.sin(_rad(wind)), math.cos(_rad(wind))];
  final v = [math.cos(_rad(wind)), -math.sin(_rad(wind))];
  Map<String, dynamic> ll(double x, double y) =>
      {'lat': centreLat + y / 111320, 'lon': centreLon + x / (111320 * math.cos(_rad(centreLat)))};
  final marks = <Map<String, dynamic>>[];
  for (final e in [
    ['Windward', 380.0, 10.0],
    ['Leeward', -360.0, 45.0],
    ['Mark 3', -120.0, -45.0],
  ]) {
    final name = e[0] as String, a = e[1] as double, c = e[2] as double;
    final x = u[0] * a + v[0] * c, y = u[1] * a + v[1] * c;
    marks.add({'id': name.toLowerCase().replaceAll(' ', ''), 'name': name, 'side': 'stbd', ...ll(x, y)});
  }
  final m3 = [u[0] * -120 + v[0] * -45, u[1] * -120 + v[1] * -45];
  final sc = [m3[0] + u[0] * 6, m3[1] - 15 + u[1] * 6];
  final fc = [m3[0] - u[0] * 18, m3[1] - u[1] * 18];
  final lines = [
    {'id': 'start', 'kind': 'start', 'a': ll(sc[0] + v[0] * 35, sc[1] + v[1] * 35), 'b': ll(sc[0] - v[0] * 35, sc[1] - v[1] * 35)},
    {'id': 'finish', 'kind': 'finish', 'a': ll(fc[0] + v[0] * 30, fc[1] + v[1] * 30), 'b': ll(fc[0] - v[0] * 30, fc[1] - v[1] * 30)},
  ];
  return {'marks': marks, 'fixes': <Object>[], 'lines': lines};
}

/// Files for a demo race morning: three pucks + a mate's phone GPX, all starting at [t0] (UTC).
Map<String, String> demoDayFiles(DateTime t0) {
  String hhmmss(DateTime t) => '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
  final out = <String, String>{};
  for (final f in const [
    ['puck1', 4.6, 11, 0.0, 12.0],
    ['puck2', 4.4, 23, 8.0, 5.0],
    ['puck3', 4.2, 37, -8.0, 24.0],
  ]) {
    out['${f[0]}_${hhmmss(t0)}.csv'] = toPuckCsv(twoRaces(f[1] as double, f[2] as int, f[3] as double, f[4] as double, t0));
  }
  out['Steve_phone.gpx'] = toGpx('Steve', twoRaces(4.3, 51, 20, 15, t0));
  return out;
}
