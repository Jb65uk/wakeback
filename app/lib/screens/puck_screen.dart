// One puck, from the app: its live page (calibration, tracks, settings) and a firmware update, without
// touching Android's WiFi settings or typing an address.
//
// Reaching it: on the pad and checked in → straight over the hotspot (its IP comes with the check-in).
// Otherwise the puck's own setup WiFi, which needs the button held 6 s; the app joins it like Set up a puck.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../puck/puck_wifi.dart';
import '../updates.dart';
import '../widgets/common.dart';
import 'web_page.dart';

class PuckScreen extends StatefulWidget {
  final MyPuck puck;
  const PuckScreen({super.key, required this.puck});
  @override
  State<PuckScreen> createState() => _PuckScreenState();
}

class _PuckScreenState extends State<PuckScreen> {
  PuckReach? _reach;
  PuckStatus? _status;
  String? _step, _error;
  bool _busy = false;
  PuckFirmware? _latest;
  String? _latestError;
  double? _flashProgress;

  @override
  void initState() {
    super.initState();
    _checkLatest();
  }

  @override
  void dispose() {
    _reach?.release();
    super.dispose();
  }

  Future<void> _checkLatest() async {
    try {
      final f = await Updates.instance.latestPuckFirmware();
      if (mounted) setState(() => _latest = f);
    } catch (e) {
      if (mounted) setState(() => _latestError = friendly(e));
    }
  }

  /// Find the puck and read its status. Over the hotspot if the dock says it's on the pad; its setup WiFi
  /// only when [setupWifi] (the user chose that, having held the button).
  Future<bool> _connect({bool setupWifi = false}) async {
    if (_reach != null) return true;
    setState(() {
      _busy = true;
      _error = null;
      _step = null;
    });
    try {
      PuckReach r;
      if (setupWifi) {
        setState(() => _step = 'Joining the puck\'s WiFi — tap Connect when your phone asks…');
        await PuckWifi.join();
        final st0 = await PuckApi().status();
        if (!st0.isPuck) throw const PuckException('That network isn\'t a WakeBack puck.');
        r = const PuckReach('http://192.168.4.1', true);
      } else {
        r = await PuckReach.find(widget.puck.puck, allowSetupWifi: false, onStep: (s) {
          if (mounted) setState(() => _step = s);
        });
      }
      final st = await PuckApi(r.base).status();
      if (!mounted) return false;
      setState(() {
        _reach = r;
        _status = st;
        _step = null;
      });
      if (st.fw.isNotEmpty && st.fw != widget.puck.fw) {
        await app.putMyPuck(MyPuck(puck: widget.puck.puck, keyId: widget.puck.keyId, setUpMs: widget.puck.setUpMs, fw: st.fw, hotspot: widget.puck.hotspot));
      }
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPage({bool setupWifi = false}) async {
    if (!await _connect(setupWifi: setupWifi) || !mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerViewerPage(url: '${_reach!.base}/', title: 'Puck ${widget.puck.puck}')));
    // the page may have changed things (or the puck left setup mode): read it again next time
    if (mounted) setState(() => _status = null);
  }

  Future<bool> _onPad() async => PuckReach.docked(await PuckReach.dockPucks(), widget.puck.puck);

  Future<void> _update() async {
    final f = _latest;
    if (f == null) return;
    if (!await confirm(context, 'Update puck ${widget.puck.puck} to ${f.version}?',
        'The puck restarts with the new firmware; a bad image rolls back by itself. Takes about a minute. Keep the phone next to the puck.',
        ok: 'Update')) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _flashProgress = 0;
      _step = 'Downloading firmware ${f.version}…';
    });
    List<int> bin;
    try {
      // needs the internet: do it before the phone may hop onto the puck's WiFi
      bin = await Updates.instance.downloadPuckFirmware(f);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendly(e);
          _busy = false;
          _flashProgress = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!await _connect(setupWifi: _reach == null && !await _onPad()) || !mounted) {
      setState(() => _flashProgress = null);
      return;
    }
    setState(() {
      _busy = true;
      _step = 'Sending ${(bin.length / 1024).round()} KB to the puck…';
    });
    try {
      await PuckApi(_reach!.base).flash(bin);
      if (!mounted) return;
      setState(() {
        _step = null;
        _flashProgress = null;
        _status = null;
        _reach = null; // it restarts: whatever we were on is gone
      });
      await app.putMyPuck(MyPuck(puck: widget.puck.puck, keyId: widget.puck.keyId, setUpMs: widget.puck.setUpMs, fw: f.version, hotspot: widget.puck.hotspot));
      if (mounted) toast(context, 'Firmware ${f.version} sent. The puck is restarting; give it a minute, then it checks in as usual.');
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      await PuckWifi.leave();
      if (mounted) {
        setState(() {
          _busy = false;
          _flashProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = widget.puck;
    final st = _status;
    final fw = st?.fw.isNotEmpty == true ? st!.fw : p.fw;
    final canUpdate = _latest != null && (fw.isEmpty || _latest!.newerThan(fw));
    return Scaffold(
      appBar: AppBar(title: Text('Puck ${p.puck}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                CircleAvatar(radius: 22, backgroundColor: t.colorScheme.primary, child: Text('${p.puck}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 18))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Firmware ${fw.isEmpty ? 'unknown' : fw}', style: t.textTheme.titleMedium),
                    if (st != null)
                      Text(
                        [
                          if (st.batteryPct >= 0) 'battery ${st.batteryPct}%',
                          '${st.tracks} track${st.tracks == 1 ? '' : 's'} on it',
                          _reach?.viaSetupWifi == true ? 'on its setup WiFi' : 'on the hotspot',
                        ].join(' · '),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      )
                    else
                      Text(p.keyId > 0 ? 'Uploads as you' : 'No account key', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ]),
              if (_step != null) ...[
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_step!, style: t.textTheme.bodyMedium)),
                ]),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.red.shade900.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8)),
                  child: Text(_error!, style: t.textTheme.bodyMedium),
                ),
              ],
            ]),
          ),
        ),
        const SectionLabel('Settings and calibration'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Open the puck\'s page'),
              subtitle: const Text('Boat is level, mounted on deck / under thwart, record on/off, tracks on the puck, WiFi. '
                  'Puck on the pad, hotspot on: it answers within a minute.'),
              isThreeLine: true,
              enabled: !_busy,
              onTap: _busy ? null : () => _openPage(),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.wifi_find),
              title: const Text('Not on the pad? Use its setup WiFi'),
              subtitle: const Text('Hold the puck\'s button 6 seconds (five quick blinks), then tap this and Connect when your phone asks.'),
              isThreeLine: true,
              enabled: !_busy,
              onTap: _busy ? null : () => _openPage(setupWifi: true),
            ),
          ]),
        ),
        const SectionLabel('Firmware'),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(canUpdate ? Icons.system_update : Icons.verified_outlined, color: canUpdate ? t.colorScheme.primary : null),
              title: Text(_latest == null
                  ? (_latestError ?? 'Checking for puck firmware…')
                  : canUpdate
                      ? 'Update available: ${_latest!.version}'
                      : 'Up to date (${_latest!.version} is the latest)'),
              subtitle: _latest != null && _latest!.notes.isNotEmpty ? Text(_latest!.notes, maxLines: 4, overflow: TextOverflow.ellipsis) : null,
              trailing: canUpdate ? FilledButton(onPressed: _busy ? null : _update, child: const Text('Update')) : null,
            ),
            if (_flashProgress != null) const LinearProgressIndicator(),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Hint('The app downloads the new firmware from GitHub, then sends it to the puck over the hotspot or its setup WiFi. '
                  'The puck restarts; if the new firmware doesn\'t run properly it goes back to the old one by itself.'),
            ),
          ]),
        ),
      ]),
    );
  }
}
