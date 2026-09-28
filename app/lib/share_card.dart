// A picture of a session to drop in the club WhatsApp: the track(s) on a dark card with the day's numbers.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'app_state.dart';
import 'dock/stats.dart';

class ShareTrack {
  final String name;
  final List<List<double>> pts; // [lat, lon]
  final Map<String, dynamic> stats;
  final bool mine;
  const ShareTrack(this.name, this.pts, this.stats, this.mine);
}

const _colours = [Color(0xFF4FC3F7), Color(0xFFFFB74D), Color(0xFF81C784), Color(0xFFE57373), Color(0xFFBA68C8), Color(0xFFFFF176)];

/// Draw the card (1080 x 1350, portrait like a phone screen) and return the PNG bytes.
Future<ui.Image> paintShareCard({required String title, required String subtitle, required List<ShareTrack> tracks, required String who}) async {
  const w = 1080.0, h = 1350.0;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, const Rect.fromLTWH(0, 0, w, h));
  // background
  c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF13293A));
  c.drawRect(const Rect.fromLTWH(0, 0, w, h),
      Paint()..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, h), [const Color(0xFF0D2231), const Color(0xFF1B3A52)]));
  // title
  _text(c, 'Wake', const Offset(60, 60), 64, Colors.white, FontWeight.w800, tail: ('Back', const Color(0xFF4FC3F7)));
  _text(c, title, const Offset(60, 150), 44, Colors.white, FontWeight.w700);
  _text(c, subtitle, const Offset(60, 210), 32, Colors.white70, FontWeight.w400);

  // the map area: fit all tracks, keep aspect (lon squashed by cos(lat))
  const mapRect = Rect.fromLTWH(60, 290, w - 120, 700);
  c.drawRRect(RRect.fromRectAndRadius(mapRect, const Radius.circular(24)), Paint()..color = const Color(0xFF0B1D2B));
  final all = tracks.expand((t) => t.pts).toList();
  if (all.isNotEmpty) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in all) {
      minLat = math.min(minLat, p[0]);
      maxLat = math.max(maxLat, p[0]);
      minLon = math.min(minLon, p[1]);
      maxLon = math.max(maxLon, p[1]);
    }
    final k = math.cos((minLat + maxLat) / 2 * math.pi / 180);
    final spanX = math.max(1e-6, (maxLon - minLon) * k), spanY = math.max(1e-6, maxLat - minLat);
    final pad = 40.0;
    final scale = math.min((mapRect.width - 2 * pad) / spanX, (mapRect.height - 2 * pad) / spanY);
    final ox = mapRect.left + (mapRect.width - spanX * scale) / 2, oy = mapRect.top + (mapRect.height - spanY * scale) / 2;
    Offset at(List<double> p) => Offset(ox + (p[1] - minLon) * k * scale, oy + (maxLat - p[0]) * scale);
    // faint grid
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    for (var x = mapRect.left; x < mapRect.right; x += 70) {
      c.drawLine(Offset(x, mapRect.top), Offset(x, mapRect.bottom), grid);
    }
    for (var y = mapRect.top; y < mapRect.bottom; y += 70) {
      c.drawLine(Offset(mapRect.left, y), Offset(mapRect.right, y), grid);
    }
    c.save();
    c.clipRRect(RRect.fromRectAndRadius(mapRect, const Radius.circular(24)));
    // others first, thin; mine last, thick
    final order = [...tracks.where((t) => !t.mine), ...tracks.where((t) => t.mine)];
    for (var i = 0; i < order.length; i++) {
      final t = order[i];
      if (t.pts.length < 2) continue;
      final colour = t.mine ? const Color(0xFF4FC3F7) : _colours[(i + 1) % _colours.length];
      final path = Path()..moveTo(at(t.pts.first).dx, at(t.pts.first).dy);
      final step = math.max(1, t.pts.length ~/ 4000); // no need for every 10 Hz point
      for (var j = step; j < t.pts.length; j += step) {
        final o = at(t.pts[j]);
        path.lineTo(o.dx, o.dy);
      }
      path.lineTo(at(t.pts.last).dx, at(t.pts.last).dy);
      if (t.mine) {
        c.drawPath(
            path,
            Paint()
              ..color = colour.withValues(alpha: 0.35)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 14
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round);
      }
      c.drawPath(
          path,
          Paint()
            ..color = t.mine ? colour : colour.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = t.mine ? 5 : 3
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
      // start / finish dots
      c.drawCircle(at(t.pts.first), t.mine ? 10 : 6, Paint()..color = Colors.white);
      c.drawCircle(at(t.pts.last), t.mine ? 10 : 6, Paint()..color = colour);
    }
    c.restore();
    // legend, when there's more than one boat
    if (tracks.length > 1) {
      var y = mapRect.top + 24;
      for (var i = 0; i < order.length; i++) {
        final t = order[i];
        final colour = t.mine ? const Color(0xFF4FC3F7) : _colours[(i + 1) % _colours.length];
        c.drawCircle(Offset(mapRect.left + 30, y + 12), 8, Paint()..color = colour);
        _text(c, t.name, Offset(mapRect.left + 50, y), 24, Colors.white70, t.mine ? FontWeight.w700 : FontWeight.w400);
        y += 36;
      }
    }
  }

  // the numbers (mine, or all if none are mine)
  final mine = tracks.where((t) => t.mine).toList();
  final use = mine.isNotEmpty ? mine : tracks;
  var dist = 0.0, top = 0.0, moving = 0;
  var wsum = 0.0;
  for (final t in use) {
    dist += (t.stats['dist_nm'] as num?)?.toDouble() ?? 0;
    top = math.max(top, (t.stats['max_kn'] as num?)?.toDouble() ?? 0);
    final m = (t.stats['moving_s'] as num?)?.toInt() ?? 0;
    moving += m;
    wsum += ((t.stats['avg_kn'] as num?)?.toDouble() ?? 0) * m;
  }
  final avg = moving > 0 ? wsum / moving : 0.0;
  final tiles = [
    (dist.toStringAsFixed(1), 'nautical miles'),
    (top.toStringAsFixed(1), 'kn top speed'),
    (avg.toStringAsFixed(1), 'kn average'),
    (moving >= 3600 ? '${(moving / 3600).toStringAsFixed(1)} h' : '${moving ~/ 60} min', 'on the water'),
  ];
  const tileY = 1030.0;
  final tileW = (w - 120 - 3 * 16) / 4;
  for (var i = 0; i < tiles.length; i++) {
    final r = Rect.fromLTWH(60 + i * (tileW + 16), tileY, tileW, 150);
    c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(18)), Paint()..color = Colors.white.withValues(alpha: 0.07));
    _text(c, tiles[i].$1, Offset(r.left + 20, r.top + 22), 52, Colors.white, FontWeight.w800);
    _text(c, tiles[i].$2, Offset(r.left + 20, r.top + 96), 24, Colors.white70, FontWeight.w400);
  }
  _text(c, who, const Offset(60, 1230), 28, Colors.white54, FontWeight.w400);
  _text(c, 'wakeback', Offset(w - 60 - 170, 1230), 28, const Color(0xFF4FC3F7), FontWeight.w700);
  return rec.endRecording().toImage(w.toInt(), h.toInt());
}

void _text(Canvas c, String s, Offset at, double size, Color colour, FontWeight weight, {(String, Color)? tail}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(fontSize: size, color: colour, fontWeight: weight, height: 1.1),
      children: tail == null ? null : [TextSpan(text: tail.$1, style: TextStyle(color: tail.$2))],
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 960);
  tp.paint(c, at);
}

/// Build the card for a session and hand it to the share sheet.
Future<void> shareSession(BuildContext context, Map<String, dynamic> session) async {
  final id = session['id'] as String;
  final files = (session['files'] as List).cast<String>();
  final mine = ((session['mine'] as List?) ?? const []).cast<String>().toSet();
  final owners = (session['owners'] as Map?) ?? const {};
  final stats = (session['stats'] as Map?) ?? const {};
  final tracks = <ShareTrack>[];
  for (final f in files) {
    final st = stats[f];
    if (st is! Map) continue;
    try {
      final text = await app.store.trackText(id, f);
      final name = '${owners[f] ?? ''}'.isNotEmpty ? '${owners[f]}' : f.replaceAll(RegExp(r'\.(csv|gpx)$', caseSensitive: false), '');
      tracks.add(ShareTrack(name, trackPositions(text, f), st.cast<String, dynamic>(), mine.contains(f)));
    } catch (_) {}
  }
  if (tracks.isEmpty) throw StateError('No tracks to draw');
  final date = DateTime.tryParse('${session['date']}');
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final title = date == null ? '${session['date']}' : '${days[date.weekday - 1]} ${date.day} ${months[date.month - 1]} ${date.year}';
  final img = await paintShareCard(
    title: title,
    subtitle: '${session['venue_name'] ?? ''}${tracks.length > 1 ? '  ·  ${tracks.length} boats' : ''}',
    tracks: tracks,
    who: app.profileName.isNotEmpty ? app.profileName : 'a WakeBack sailor',
  );
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  if (bytes == null) throw StateError('Could not draw the card');
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/wakeback-${session['date']}.png');
  await f.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
  await Share.shareXFiles([XFile(f.path, mimeType: 'image/png')], text: 'WakeBack · $title · ${session['venue_name'] ?? ''}');
}
