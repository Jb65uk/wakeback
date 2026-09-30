// The phone's own GPS track while recording: which fixes to keep, running totals, and the files it
// becomes. Plain Dart (no plugins) so it's unit-tested; recorder.dart feeds it from the GPS.
//
// Saved as the puck's CSV (t_ms,lat,lon,sog_kn,hdg) so the phone's track is a first-class track:
// the viewer, stats, bests, badges and wind-vs-speed (which needs heading) all read it like a puck's.
import 'dart:math' as math;

const double kMsToKn = 1.943844;
const double kMToNm = 1 / 1852;

class Fix {
  final int t; // ms since epoch, UTC
  final double lat, lon;
  final double sogKn;
  final double? hdg;
  final double acc; // metres
  final int seg; // bumps on every resume, so a pause isn't counted as sailing
  const Fix(this.t, this.lat, this.lon, this.sogKn, this.hdg, this.acc, this.seg);

  /// One line of the crash-safe draft file.
  String get draftLine =>
      '$t,${lat.toStringAsFixed(7)},${lon.toStringAsFixed(7)},${sogKn.toStringAsFixed(2)},${hdg?.round() ?? ''},${acc.round()},$seg';

  static Fix? fromDraftLine(String l) {
    final c = l.split(',');
    if (c.length < 7) return null;
    final t = int.tryParse(c[0]), lat = double.tryParse(c[1]), lon = double.tryParse(c[2]);
    final sog = double.tryParse(c[3]), acc = double.tryParse(c[5]), seg = int.tryParse(c[6]);
    if (t == null || lat == null || lon == null || sog == null || acc == null || seg == null) return null;
    return Fix(t, lat, lon, sog, c[4].isEmpty ? null : double.tryParse(c[4]), acc, seg);
  }
}

double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8, d = math.pi / 180;
  final dLat = (lat2 - lat1) * d, dLon = (lon2 - lon1) * d;
  final s = math.pow(math.sin(dLat / 2), 2) + math.cos(lat1 * d) * math.cos(lat2 * d) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(s.toDouble())));
}

double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  const d = math.pi / 180;
  final y = math.sin((lon2 - lon1) * d) * math.cos(lat2 * d);
  final x = math.cos(lat1 * d) * math.sin(lat2 * d) - math.sin(lat1 * d) * math.cos(lat2 * d) * math.cos((lon2 - lon1) * d);
  return (math.atan2(y, x) / d + 360) % 360;
}

/// What the GPS said, before any filtering. Speed/heading null when the phone didn't report them.
class RawFix {
  final int t;
  final double lat, lon, acc;
  final double? speedMs, heading;
  const RawFix(this.t, this.lat, this.lon, this.acc, {this.speedMs, this.heading});
}

enum FixResult { recorded, still, weak, glitch }

class TrackLog {
  /// Fixes worse than this (metres) are ignored.
  double maxAcc;
  TrackLog({this.maxAcc = 30});

  final List<Fix> fixes = [];
  int seg = 0;
  double distM = 0, maxKn = 0;

  /// Live values for the display (also updated while paused).
  double sogKn = 0;
  double? hdg;
  RawFix? _prev;

  /// Take one GPS fix. [recording] false = paused: show speed, keep nothing.
  FixResult add(RawFix f, {required bool recording}) {
    if (f.acc > maxAcc) return FixResult.weak;
    double? sog = f.speedMs != null && f.speedMs! >= 0 ? f.speedMs! * kMsToKn : null;
    var h = f.heading;
    final p = _prev;
    if (p != null) {
      final moved = haversineM(p.lat, p.lon, f.lat, f.lon), dt = (f.t - p.t) / 1000;
      if (sog == null && dt > 0) sog = moved / dt * kMsToKn;
      if (h == null && moved > 3) h = bearingDeg(p.lat, p.lon, f.lat, f.lon);
    }
    sog ??= 0;
    if (sog > 40) return FixResult.glitch; // a dinghy isn't doing 40 kn: a bad fix
    _prev = f;
    sogKn = sogKn * 0.4 + sog * 0.6;
    if (h != null) hdg = h;
    if (!recording) return FixResult.still;

    final last = fixes.isEmpty ? null : fixes.last;
    var d = 0.0;
    if (last != null && last.seg == seg) {
      d = haversineM(last.lat, last.lon, f.lat, f.lon);
      // sitting still: the fix wobbles about without the boat going anywhere. Keep a point every 10 s
      // (so the track has no holes) but don't count the wobble as distance.
      if (d < math.max(2, f.acc * 0.5) && sog < 0.8) {
        if (f.t - last.t < 10000) return FixResult.still;
        d = 0;
      }
    }
    fixes.add(Fix(f.t, f.lat, f.lon, sog, h, f.acc, seg));
    distM += d;
    if (sog > maxKn) maxKn = sog;
    return FixResult.recorded;
  }

  /// A recovered draft: rebuild totals from its fixes.
  void restore(List<Fix> fs) {
    fixes
      ..clear()
      ..addAll(fs);
    distM = 0;
    maxKn = 0;
    for (var i = 0; i < fs.length; i++) {
      if (i > 0 && fs[i].seg == fs[i - 1].seg) {
        final d = haversineM(fs[i - 1].lat, fs[i - 1].lon, fs[i].lat, fs[i].lon);
        if (!(d < math.max(2, fs[i].acc * 0.5) && fs[i].sogKn < 0.8)) distM += d; // same rule as add()
      }
      maxKn = math.max(maxKn, fs[i].sogKn);
    }
    seg = fs.isEmpty ? 0 : fs.last.seg + 1;
    _prev = null;
  }

  void newSegment() {
    seg++;
    _prev = null;
  }

  /// Time between fixes in the same segment (pauses left out).
  int get sailedMs {
    var ms = 0;
    for (var i = 1; i < fixes.length; i++) {
      if (fixes[i].seg == fixes[i - 1].seg) ms += fixes[i].t - fixes[i - 1].t;
    }
    return ms;
  }

  double get distNm => distM * kMToNm;

  String toCsv() {
    final b = StringBuffer('t_ms,lat,lon,sog_kn,hdg\n');
    for (final f in fixes) {
      b.writeln('${f.t},${f.lat.toStringAsFixed(7)},${f.lon.toStringAsFixed(7)},${f.sogKn.toStringAsFixed(2)},${f.hdg?.round() ?? ''}');
    }
    return b.toString();
  }

  String toGpx({String name = 'Sail'}) {
    String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="WakeBack" xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln(' <trk><name>${esc(name)}</name><type>sailing</type>');
    int? seg;
    for (final f in fixes) {
      if (f.seg != seg) {
        if (seg != null) b.writeln('  </trkseg>');
        b.writeln('  <trkseg>');
        seg = f.seg;
      }
      final time = DateTime.fromMillisecondsSinceEpoch(f.t, isUtc: true).toIso8601String();
      b.writeln('   <trkpt lat="${f.lat.toStringAsFixed(7)}" lon="${f.lon.toStringAsFixed(7)}"><time>$time</time>'
          '<extensions><speed>${(f.sogKn / kMsToKn).toStringAsFixed(2)}</speed>${f.hdg == null ? '' : '<course>${f.hdg!.round()}</course>'}</extensions></trkpt>');
    }
    if (seg != null) b.writeln('  </trkseg>');
    b
      ..writeln(' </trk>')
      ..writeln('</gpx>');
    return b.toString();
  }

  /// phone_2026-09-30_1402 (local time the sail started).
  String fileBase() {
    final d = DateTime.fromMillisecondsSinceEpoch(fixes.isEmpty ? DateTime.now().millisecondsSinceEpoch : fixes.first.t);
    String p(int n) => n.toString().padLeft(2, '0');
    return 'phone_${d.year}-${p(d.month)}-${p(d.day)}_${p(d.hour)}${p(d.minute)}';
  }
}
