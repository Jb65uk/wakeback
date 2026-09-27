// Port of tools/fake_pucks.py: pretend pucks checking in to the phone's dock over HTTP,
// exactly as real pucks on the hotspot will. P4 comes back from sailing after ~20 s
// and uploads a fresh session through /api/upload.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'fake_race.dart';

/// Top-level so it can run on a background isolate via compute().
String _genSession(List<int> a) =>
    toPuckCsv(simBoat(4.5, a[0], 0, 12, wind: 260, t0: DateTime.fromMillisecondsSinceEpoch(a[1], isUtc: true), laps: 1));

class _Puck {
  double pct;
  String state; // charging | full | not
  bool onPad;
  final String fw;
  final int free;
  int? backIn; // seconds until it comes ashore
  _Puck(this.pct, this.state, this.onPad, this.fw, this.free, {this.backIn});
}

int mvFor(double pct) {
  const table = [[100, 4200], [90, 4100], [78, 4000], [62, 3900], [45, 3800], [35, 3750], [22, 3700], [12, 3650], [6, 3600], [0, 3300]];
  for (var i = 0; i < table.length - 1; i++) {
    final p1 = table[i][0], v1 = table[i][1], p2 = table[i + 1][0], v2 = table[i + 1][1];
    if (pct >= p2) return (v2 + (v1 - v2) * (pct - p2) / (p1 - p2)).truncate();
  }
  return 3300;
}

class DemoPucks extends ChangeNotifier {
  final String dock; // e.g. http://127.0.0.1:5000
  DemoPucks(this.dock);

  Timer? _timer;
  DateTime? _started;
  late Map<int, _Puck> _pucks;
  final _rnd = math.Random();
  String? lastEvent;
  bool get running => _timer != null;
  static const every = Duration(seconds: 3);

  Future<void> _post(String path, Map<String, Object?> body) async {
    await http
        .post(Uri.parse('$dock$path'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 5));
  }

  void start() {
    if (running) return;
    _pucks = {
      1: _Puck(100, 'full', true, '0.3.1', 14100),
      2: _Puck(64, 'charging', true, '0.3.1', 13900),
      3: _Puck(28, 'charging', true, '0.3.0', 12200),
      4: _Puck(71, 'not', false, '0.3.1', 13000, backIn: 20),
      5: _Puck(47, 'not', true, '0.3.1', 14000),
    };
    _started = DateTime.now();
    // P4 was lifted off the pad this morning: it says so as it leaves
    _post('/api/pucks/checkin', {'puck': 4, 'battery_mv': mvFor(98), 'charging': 'not', 'on_pad': false, 'free_kb': 13000, 'total_kb': 14336, 'fw': '0.3.1'})
        .catchError((Object _) {});
    _timer = Timer.periodic(every, (_) => _tick());
    _tick();
    lastEvent = 'Demo pucks checking in every 3 s. P4 is out sailing and comes back in about 20 s.';
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    lastEvent = 'Demo pucks stopped. They drop off the Dock page after 90 s.';
    notifyListeners();
  }

  bool _busy = false;
  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      for (final e in _pucks.entries) {
        final n = e.key, p = e.value;
        if (!p.onPad) {
          if (p.backIn != null && DateTime.now().difference(_started!).inSeconds > p.backIn!) {
            await _post('/api/pucks/checkin', {
              'puck': n, 'battery_mv': mvFor(p.pct), 'charging': 'charging', 'on_pad': true,
              'free_kb': p.free, 'total_kb': 14336, 'fw': p.fw, 'pending': 1,
            });
            final r = await _uploadSession(n); // throws if it fails -> tried again next tick
            p.onPad = true;
            p.state = 'charging';
            p.backIn = null;
            lastEvent = 'P$n docked and uploaded ${r['file']} to ${r['session']}';
            notifyListeners();
          }
          continue;
        }
        if (p.state == 'charging') {
          p.pct = math.min(100, p.pct + 1.5);
          if (p.pct >= 100) p.state = 'full';
        } else if (p.state == 'not') {
          p.pct = math.max(0, p.pct - 0.05);
        }
        await _post('/api/pucks/checkin', {
          'puck': n, 'battery_mv': mvFor(p.pct), 'charging': p.state, 'on_pad': true,
          'free_kb': p.free, 'total_kb': 14336, 'fw': p.fw, 'pending': 0, 'rssi': -60 + _rnd.nextInt(21),
        });
      }
    } catch (e) {
      lastEvent = 'Demo pucks can\'t reach the dock: $e';
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  Future<Map<String, dynamic>> _uploadSession(int n) async {
    final now = DateTime.now().toUtc();
    final t0 = DateTime.utc(now.year, now.month, now.day, now.hour, now.minute, now.second).subtract(const Duration(minutes: 50));
    final seed = 1 + _rnd.nextInt(999);
    final csv = await compute(_genSession, [seed, t0.millisecondsSinceEpoch]);
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'puck${n}_${two(t0.hour)}${two(t0.minute)}${two(t0.second)}.csv';
    final req = http.MultipartRequest('POST', Uri.parse('$dock/api/upload'))
      ..fields['puck'] = 'puck$n'
      ..files.add(http.MultipartFile.fromString('file', csv, filename: name));
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)));
    return (jsonDecode(res.body) as Map).cast<String, dynamic>();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
