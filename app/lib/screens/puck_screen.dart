// One puck, from the app: what it's doing, the everyday buttons (level, which way up, upload now, record,
// sleep) and a firmware update — all over Bluetooth, so the puck only has to be awake and within reach.
//
// Its full web page (tracks on it, WiFi details, the rest of the calibration) is still there as a second
// route: over the hotspot when it's on the pad, or its own setup WiFi (button held 6 s) when it isn't.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../puck/puck_ble.dart';
import '../puck/puck_wifi.dart';
import '../updates.dart';
import '../widgets/common.dart';
import 'guide_screen.dart';
import 'web_page.dart';

class PuckScreen extends StatefulWidget {
  final MyPuck puck;
  const PuckScreen({super.key, required this.puck});
  @override
  State<PuckScreen> createState() => _PuckScreenState();
}

class _PuckScreenState extends State<PuckScreen> {
  PuckBle? _ble;
  StreamSubscription<bool>? _link;
  PuckReach? _reach;
  PuckStatus? _status;
  bool _statusLive = false; // the status card shows a live puck (false: the last thing it said before the link dropped)
  String? _step, _error;
  bool _busy = false;
  PuckFirmware? _latest;
  String? _latestError;
  double? _flashProgress;

  @override
  void initState() {
    super.initState();
    _checkLatest();
    _connectBle();
  }

  @override
  void dispose() {
    _link?.cancel();
    _ble?.disconnect();
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

  Future<void> _rememberFw(String fw) async {
    if (fw.isNotEmpty && fw != widget.puck.fw) {
      await app.putMyPuck(MyPuck(puck: widget.puck.puck, keyId: widget.puck.keyId, setUpMs: widget.puck.setUpMs, fw: fw, hotspot: widget.puck.hotspot));
    }
  }

  // ---------------------------------------------------------------- Bluetooth

  /// Connect over Bluetooth (if not already) and read the puck. False, with [_error] set, if it isn't about.
  Future<bool> _connectBle() async {
    if (_ble?.isConnected == true) return true;
    setState(() {
      _busy = true;
      _error = null;
      _step = 'Looking for puck ${widget.puck.puck} over Bluetooth…';
    });
    try {
      final b = await PuckBle.connect(widget.puck.puck);
      if (!mounted) {
        await b.disconnect();
        return false;
      }
      await _link?.cancel();
      _link = b.connected.listen((on) {
        if (!on && mounted && identical(_ble, b)) {
          setState(() {
            _ble = null;
            _statusLive = false;
          });
        }
      });
      setState(() {
        _ble = b;
        _step = 'Reading the puck…';
      });
      final st = await b.status();
      if (!mounted) return false;
      setState(() {
        _status = st;
        _statusLive = true;
        _step = null;
      });
      await _rememberFw(st.fw);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendly(e);
          _step = null;
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final b = _ble;
    if (b == null || !b.isConnected) {
      await _connectBle();
      return;
    }
    try {
      final st = await b.status();
      if (mounted) {
        setState(() {
          _status = st;
          _statusLive = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    }
  }

  /// One button: connect if needed, send the command, show the puck's answer, read it again.
  Future<void> _do(String doing, Future<Map<String, dynamic>> Function(PuckBle b) f, {bool thenRefresh = true}) async {
    if (!await _connectBle() || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _step = doing;
    });
    try {
      final j = await f(_ble!);
      if (!mounted) return;
      final msg = '${j['msg'] ?? ''}';
      if (msg.isNotEmpty) toast(context, msg);
      if (thenRefresh) await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
        });
      }
    }
  }

  Future<void> _sleep() async {
    if (!await confirm(context, 'Put puck ${widget.puck.puck} to sleep?', 'It wakes again when you press its button or put it on the pad.', ok: 'Sleep')) return;
    await _do('Sending it to sleep…', (b) => b.command('sleep'), thenRefresh: false);
    if (!mounted) return;
    await _link?.cancel();
    _link = null;
    await _ble?.disconnect();
    if (!mounted) return;
    setState(() {
      _ble = null;
      _statusLive = false;
      _error = null;
    });
  }

  // ---------------------------------------------------------------- the web page (WiFi)

  /// Find the puck over WiFi and read its status. Over the hotspot if the dock says it's on the pad; its setup
  /// WiFi only when [setupWifi] (the user chose that, having held the button).
  Future<bool> _connectWifi({bool setupWifi = false}) async {
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
        _statusLive = true;
        _step = null;
      });
      await _rememberFw(st.fw);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendly(e);
          _step = null;
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPage({bool setupWifi = false}) async {
    if (!await _connectWifi(setupWifi: setupWifi) || !mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerViewerPage(url: '${_reach!.base}/', title: 'Puck ${widget.puck.puck}')));
    // the page may have changed things (or the puck left setup mode): let go of that route and read it again
    if (!mounted) return;
    final r = _reach;
    setState(() => _reach = null);
    await r?.release();
    await _refresh();
  }

  Future<bool> _onPad() async => PuckReach.docked(await PuckReach.dockPucks(), widget.puck.puck);

  // ---------------------------------------------------------------- firmware

  Future<void> _update() async {
    final f = _latest;
    if (f == null) return;
    if (!await confirm(context, 'Update puck ${widget.puck.puck} to ${f.version}?',
        'The puck restarts with the new firmware; a bad image rolls back by itself. Takes a minute or two. Keep the phone next to the puck.',
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
          _step = null;
          _flashProgress = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    // Bluetooth first; the puck's web page (hotspot or setup WiFi) only if this phone has no Bluetooth to offer
    final haveBle = await PuckBle.available();
    final overBle = haveBle && await _connectBle();
    if (!mounted) return;
    if (!overBle) {
      if (haveBle) {
        // Bluetooth is fine, the puck just wasn't heard (asleep?): _connectBle has said so
        setState(() => _flashProgress = null);
        return;
      }
      if (!await _connectWifi(setupWifi: _reach == null && !await _onPad()) || !mounted) {
        setState(() => _flashProgress = null);
        return;
      }
    }
    setState(() {
      _busy = true;
      _step = 'Sending ${(bin.length / 1024).round()} KB to the puck…';
    });
    try {
      if (overBle) {
        await _ble!.flash(bin, progress: (p) {
          if (mounted) setState(() => _flashProgress = p);
        });
      } else {
        await PuckApi(_reach!.base).flash(bin);
      }
      if (!mounted) return;
      await _link?.cancel();
      _link = null;
      setState(() {
        _step = null;
        _flashProgress = null;
        _statusLive = false;
        _ble = null; // it restarts: whatever we were on is gone
        _reach = null;
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
          _step = null;
          _flashProgress = null;
        });
      }
    }
  }

  // ---------------------------------------------------------------- the screen

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = widget.puck;
    final st = _status;
    final fw = st?.fw.isNotEmpty == true ? st!.fw : p.fw;
    final canUpdate = _latest != null && (fw.isEmpty || _latest!.newerThan(fw));
    final live = _ble?.isConnected == true && _statusLive;
    final recording = st?.recording == true;
    final dim = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: Text('Puck ${p.puck}'), actions: [
        IconButton(
          tooltip: 'Guide',
          icon: const Icon(Icons.help_outline),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GuideScreen(open: GuideTopic.button))),
        ),
      ]),
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
                          if (st.batteryPct >= 0) 'battery ${st.batteryPct}%${st.charging ? ', charging' : st.batteryFull ? ', full' : ''}',
                          if (st.onPad && !st.charging && !st.batteryFull) 'on the pad',
                          if (st.recording) 'recording',
                          '${st.tracks} track${st.tracks == 1 ? '' : 's'} on it',
                        ].join(' · '),
                        style: dim,
                      ),
                    Text(
                      live
                          ? 'Connected over Bluetooth'
                          : st != null
                              ? 'Not connected now (as it was last time)'
                              : p.keyId > 0
                                  ? 'Uploads as you'
                                  : 'No account key',
                      style: live ? dim?.copyWith(color: Colors.greenAccent) : dim,
                    ),
                  ]),
                ),
                if (!_busy)
                  IconButton(
                    tooltip: live ? 'Read it again' : 'Connect',
                    icon: Icon(live ? Icons.refresh : Icons.bluetooth_searching),
                    onPressed: _refresh,
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
              if (!live && _step == null) ...[
                const SizedBox(height: 8),
                const Hint('The puck has to be awake to talk: on the pad, or press its button once. Then tap the Bluetooth button above.'),
              ],
            ]),
          ),
        ),
        const SectionLabel('On the boat'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Hint('With the puck clipped in and the boat sitting level, tell it so: heel and pitch then read 0 from here. Then say which way up it\'s mounted.'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _do('Setting level…', (b) => b.command('level')),
                  icon: const Icon(Icons.straighten, size: 18),
                  label: const Text('Boat is level'),
                ),
                OutlinedButton(onPressed: _busy ? null : () => _do('Setting which way up…', (b) => b.command('orient 1')), child: const Text('Mounted on deck')),
                OutlinedButton(onPressed: _busy ? null : () => _do('Setting which way up…', (b) => b.command('orient 2')), child: const Text('Under the thwart')),
              ]),
            ]),
          ),
        ),
        const SectionLabel('Tracks and power'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Upload now'),
              subtitle: const Text('The puck goes looking for the hotspot straight away and hands over its tracks. Have the hotspot on and WakeBack open.'),
              isThreeLine: true,
              enabled: !_busy,
              onTap: _busy ? null : () => _do('Telling it to find the hotspot…', (b) => b.command('upload')),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record, color: recording ? null : Colors.redAccent),
              title: Text(recording ? 'Stop recording' : 'Start recording'),
              subtitle: Text(recording ? 'Closes the track it\'s on now; only a finished track can be uploaded.' : 'By hand. It starts by itself when the boat moves off anyway.'),
              enabled: !_busy,
              onTap: _busy ? null : () => _do(recording ? 'Stopping…' : 'Starting…', (b) => b.command(recording ? 'rec stop' : 'rec start')),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: const Text('Sleep'),
              subtitle: const Text('Saves the battery. It wakes when you press its button or put it on the pad.'),
              enabled: !_busy,
              onTap: _busy ? null : _sleep,
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
            if (_flashProgress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LinearProgressIndicator(value: _flashProgress! > 0 ? _flashProgress : null),
                  const SizedBox(height: 4),
                  Text(_flashProgress! > 0 ? '${(_flashProgress! * 100).round()}% sent' : 'Getting ready…', style: dim),
                ]),
              ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Hint('The app downloads the new firmware from GitHub and sends it to the puck over Bluetooth (the puck just has to be awake, with the '
                  'phone next to it). The puck restarts; if the new firmware doesn\'t run properly it goes back to the old one by itself.'),
            ),
          ]),
        ),
        const SectionLabel('The puck\'s full page'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Open the puck\'s page'),
              subtitle: const Text('Everything on it: the tracks, WiFi details, the rest of the calibration. Over WiFi: puck on the pad with the hotspot on, '
                  'and it answers within a minute.'),
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
      ]),
    );
  }
}
