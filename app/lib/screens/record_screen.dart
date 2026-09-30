// Record tab: sail with just the phone. Big live speed, the track as you go, Start / Pause / Finish.
// A finished sail lands in Sessions like a puck's (venue, stats, bests, sync to the server).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../record/recorder.dart';
import '../record/track_log.dart';
import '../widgets/common.dart';

const _yellow = Color(0xFFFFC72C), _red = Color(0xFFFF6B6B), _green = Color(0xFF6FD3A4);
const _tab = [FontFeature.tabularFigures()];

String _f1(double v) => (v.isFinite ? v : 0).toStringAsFixed(1);
String _hms(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 3600}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

class RecordScreen extends StatefulWidget {
  /// Open a session in Replay (after finishing).
  final void Function(String id) onOpen;
  const RecordScreen({super.key, required this.onOpen});
  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _start() => _run(() async {
        if (!await recorder.start() && mounted && recorder.problem != null) toast(context, recorder.problem!, error: true);
      });

  Future<void> _resume() => _run(() async {
        if (!await recorder.resume() && mounted && recorder.problem != null) toast(context, recorder.problem!, error: true);
      });

  Future<void> _finish() async {
    final l = recorder.log;
    if (l.fixes.length < 2) {
      if (await confirm(context, 'Nothing recorded yet', 'There aren\'t enough GPS fixes to save a track. Stop recording anyway?', ok: 'Stop', danger: true)) {
        await _run(recorder.discard);
      }
      return;
    }
    if (!mounted) return;
    final ok = await confirm(context, 'Finish this sail?',
        '${l.distNm.toStringAsFixed(2)} nm in ${_hms(recorder.elapsedMs)}. It goes into Sessions, ready to replay and sync.',
        ok: 'Finish');
    if (!ok) return;
    await _run(() async {
      final r = await recorder.finish();
      if (mounted && r != null) toast(context, 'Saved to ${r['venue_name'] ?? r['session']}');
    });
  }

  Future<void> _discard() async {
    if (await confirm(context, 'Discard this recording?', 'The track is deleted from the phone. This can\'t be undone.', ok: 'Discard', danger: true)) {
      await _run(recorder.discard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        final r = recorder, l = r.log, st = r.state;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(children: [
              Text('Record', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              _GpsPill(acc: r.accuracy, maxAcc: l.maxAcc, on: r.active),
            ]),
            const SizedBox(height: 12),
            _LiveCard(recorder: r),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                height: 220,
                color: const Color(0xFF0F2230),
                child: l.fixes.length < 2
                    ? Center(
                        child: Text(
                          st == RecState.idle ? 'Your track draws here as you sail' : 'Waiting for the first good GPS fixes…',
                          style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                        ),
                      )
                    : CustomPaint(painter: _TracePainter(l.fixes), size: Size.infinite),
              ),
            ),
            const SizedBox(height: 14),
            _controls(st),
            const SizedBox(height: 10),
            if (r.recovered)
              const Hint('This recording was cut off (the app closed or the phone restarted). Resume to carry on, or Finish to save what\'s there.')
            else if (st == RecState.idle)
              const Hint('Recording keeps going with the screen off or another app open (you\'ll see a WakeBack notification). '
                  'Don\'t swipe WakeBack away from recent apps while you sail.')
            else if (st == RecState.paused)
              const Hint('Paused. Nothing is added to the track until you resume, and the time doesn\'t count.'),
            if (r.problem != null && st == RecState.idle) ...[
              const SizedBox(height: 10),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.location_off_outlined, color: _red),
                  title: Text(r.problem!),
                  trailing: TextButton(onPressed: r.openSettings, child: const Text('Settings')),
                ),
              ),
            ],
            if (st == RecState.idle && r.lastSaved != null && r.lastSavedLog != null) ...[
              const SectionLabel('Just saved'),
              _SavedCard(res: r.lastSaved!, log: r.lastSavedLog!, onOpen: widget.onOpen),
            ],
            const SectionLabel('GPS filter'),
            Row(children: [
              const Expanded(child: Hint('Leave out fixes less accurate than this. Lower is cleaner but drops more in poor signal.')),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: const [10, 15, 20, 30, 50].contains(app.recordMaxAcc) ? app.recordMaxAcc : 30,
                items: [for (final m in const [10, 15, 20, 30, 50]) DropdownMenuItem(value: m, child: Text('± $m m'))],
                onChanged: (v) {
                  if (v == null) return;
                  app.recordMaxAcc = v;
                  recorder.log.maxAcc = v.toDouble();
                  setState(() {});
                },
              ),
            ]),
          ],
        );
      },
    );
  }

  Widget _controls(RecState st) {
    final big = WidgetStateProperty.all(const Size.fromHeight(58));
    final label = WidgetStateProperty.all(const TextStyle(fontSize: 20, fontWeight: FontWeight.w700));
    if (st == RecState.idle) {
      return FilledButton.icon(
        style: ButtonStyle(minimumSize: big, textStyle: label),
        onPressed: _busy ? null : _start,
        icon: const Icon(Icons.fiber_manual_record),
        label: const Text('Start'),
      );
    }
    return Column(children: [
      Row(children: [
        Expanded(
          child: st == RecState.recording
              ? OutlinedButton.icon(
                  style: ButtonStyle(minimumSize: big, textStyle: label),
                  onPressed: _busy ? null : () => _run(recorder.pause),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                )
              : FilledButton.icon(
                  style: ButtonStyle(minimumSize: big, textStyle: label),
                  onPressed: _busy ? null : _resume,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: ButtonStyle(
              minimumSize: big,
              textStyle: label,
              foregroundColor: WidgetStateProperty.all(_red),
              side: WidgetStateProperty.all(const BorderSide(color: _red)),
            ),
            onPressed: _busy ? null : _finish,
            icon: const Icon(Icons.stop),
            label: const Text('Finish'),
          ),
        ),
      ]),
      if (st == RecState.paused)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: _busy ? null : _discard, child: const Text('Discard recording', style: TextStyle(color: _red))),
        ),
    ]);
  }
}

class _GpsPill extends StatelessWidget {
  final double? acc, maxAcc;
  final bool on;
  const _GpsPill({required this.acc, required this.maxAcc, required this.on});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = acc;
    final c = a == null ? t.colorScheme.onSurfaceVariant : (a <= 10 ? _green : a <= (maxAcc ?? 30) ? _yellow : _red);
    final txt = !on ? 'GPS off' : a == null ? 'Finding GPS' : '± ${a.round()} m';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: t.dividerColor), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(txt, style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: _tab)),
      ]),
    );
  }
}

class _LiveCard extends StatelessWidget {
  final Recorder recorder;
  const _LiveCard({required this.recorder});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context), r = recorder, l = r.log;
    final muted = t.colorScheme.onSurfaceVariant;
    final rec = r.state == RecState.recording;
    Widget lab(String s) => Text(s.toUpperCase(), style: t.textTheme.labelSmall?.copyWith(color: muted, letterSpacing: 1.1, fontWeight: FontWeight.w600));
    Widget val(String v, [String unit = '']) => Text.rich(
          TextSpan(children: [
            TextSpan(text: v, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600, height: 1.05)),
            if (unit.isNotEmpty) TextSpan(text: ' $unit', style: TextStyle(fontSize: 15, color: muted)),
          ]),
          style: const TextStyle(fontFeatures: _tab),
          maxLines: 1,
        );
    Widget cell(String label, String v, [String unit = '']) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [lab(label), val(v, unit)]);
    final hdg = l.hdg;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                lab('Speed · kn'),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_f1(r.active ? l.sogKn : 0),
                      style: TextStyle(fontSize: 96, fontWeight: FontWeight.w800, height: .95, color: rec ? _yellow : null, fontFeatures: _tab)),
                ),
              ]),
            ),
            Expanded(
              flex: 4,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                cell('Heading', hdg == null || !r.active ? '—' : '${hdg.round() % 360}'.padLeft(3, '0'), '°'),
                const SizedBox(height: 10),
                cell('Top speed', _f1(l.maxKn), 'kn'),
              ]),
            ),
          ]),
          const Divider(height: 26),
          Row(children: [
            Expanded(child: cell('Time', _hms(r.elapsedMs))),
            Expanded(child: cell('Distance', l.distNm.toStringAsFixed(2), 'nm')),
            Expanded(child: cell('Average', _f1(r.avgKn), 'kn')),
          ]),
        ]),
      ),
    );
  }
}

class _SavedCard extends StatelessWidget {
  final Map<String, dynamic> res;
  final TrackLog log;
  final void Function(String id) onOpen;
  const _SavedCard({required this.res, required this.log, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final where = '${res['venue_name'] ?? res['session']}';
    final ms = log.sailedMs;
    final avg = ms > 0 ? log.distNm / (ms / 3600000) : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(where, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${log.distNm.toStringAsFixed(2)} nm · ${_hms(ms)} · top ${_f1(log.maxKn)} kn · avg ${_f1(avg)} kn',
              style: TextStyle(color: t.colorScheme.onSurfaceVariant, fontFeatures: _tab)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            FilledButton.tonalIcon(onPressed: () => onOpen('${res['session']}'), icon: const Icon(Icons.sailing, size: 18), label: const Text('Replay')),
            TextButton.icon(
              onPressed: () async {
                try {
                  await recorder.shareGpx(log, title: 'Sail · $where');
                } catch (e) {
                  if (context.mounted) toast(context, 'Couldn\'t share: $e', error: true);
                }
              },
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('Share GPX'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// The track so far, north up, fitted to the box, with a scale bar.
class _TracePainter extends CustomPainter {
  final List<Fix> fixes;
  final int n;
  _TracePainter(this.fixes) : n = fixes.length;

  @override
  void paint(Canvas canvas, Size size) {
    var la0 = double.infinity, la1 = -double.infinity, lo0 = double.infinity, lo1 = -double.infinity;
    for (final f in fixes) {
      la0 = math.min(la0, f.lat);
      la1 = math.max(la1, f.lat);
      lo0 = math.min(lo0, f.lon);
      lo1 = math.max(lo1, f.lon);
    }
    const pad = 18.0;
    final k = math.cos((la0 + la1) / 2 * math.pi / 180);
    // metres per degree of latitude ~111 km; keep at least a 100 m box so a still start doesn't zoom to the wobble
    final spanX = math.max((lo1 - lo0) * k, 100 / 111320), spanY = math.max(la1 - la0, 100 / 111320);
    final s = math.min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY);
    final ox = (size.width - (lo1 - lo0) * k * s) / 2, oy = (size.height - (la1 - la0) * s) / 2;
    Offset at(Fix f) => Offset(ox + (f.lon - lo0) * k * s, size.height - oy - (f.lat - la0) * s);

    final path = Path();
    for (var i = 0; i < fixes.length; i++) {
      final p = at(fixes[i]);
      if (i == 0 || fixes[i].seg != fixes[i - 1].seg) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = _yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    final start = at(fixes.first), end = at(fixes.last);
    canvas.drawCircle(start, 5, Paint()..color = Colors.white70);
    canvas.drawCircle(end, 7, Paint()..color = _yellow);
    canvas.drawCircle(
        end,
        7,
        Paint()
          ..color = const Color(0xFF13293A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);

    // scale bar: a round distance about a quarter of the width
    final mPerPx = 111320 / s;
    final want = mPerPx * size.width / 4;
    final nice = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000].lastWhere((m) => m <= want, orElse: () => 10);
    final px = nice / mPerPx;
    final y = size.height - 12, x0 = 12.0;
    final bar = Paint()
      ..color = Colors.white54
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x0, y), Offset(x0 + px, y), bar);
    canvas.drawLine(Offset(x0, y - 4), Offset(x0, y), bar);
    canvas.drawLine(Offset(x0 + px, y - 4), Offset(x0 + px, y), bar);
    final tp = TextPainter(
      text: TextSpan(text: nice >= 1000 ? '${nice ~/ 1000} km' : '$nice m', style: const TextStyle(color: Colors.white70, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x0 + px + 6, y - tp.height / 2 - 1));
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.n != n || !identical(old.fixes, fixes);
}
