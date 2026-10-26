// One puck, from the app: what it's doing, the everyday buttons (level, which way up, get its tracks, record,
// sleep) and a firmware update — all over Bluetooth, so the puck only has to be awake and within reach.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../puck/puck_ble.dart';
import '../puck/puck_pull.dart';
import '../updates.dart';
import '../widgets/common.dart';
import 'guide_screen.dart';

class PuckScreen extends StatefulWidget {
  final MyPuck puck;
  const PuckScreen({super.key, required this.puck});
  @override
  State<PuckScreen> createState() => _PuckScreenState();
}

class _PuckScreenState extends State<PuckScreen> {
  PuckBle? _ble;
  StreamSubscription<bool>? _link;
  PuckStatus? _status;
  bool _statusLive = false; // the status card shows a live puck (false: the last thing it said before the link dropped)
  String? _step, _error;
  bool _busy = false;
  PuckFirmware? _latest;
  String? _latestError;
  double? _progress; // a track pull or a firmware push, 0..1
  List<PuckTrack>? _tracks;

  @override
  void initState() {
    super.initState();
    PuckBle.busy = true; // the background watcher keeps off the link while this screen is up
    _checkLatest();
    _connect();
  }

  @override
  void dispose() {
    _link?.cancel();
    _ble?.disconnect();
    PuckBle.busy = false;
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
    if (fw.isNotEmpty && fw != widget.puck.fw) await app.putMyPuck(widget.puck.copyWith(fw: fw));
  }

  // ---------------------------------------------------------------- the link

  /// Connect over Bluetooth (if not already) and read the puck. False, with [_error] set, if it isn't about.
  Future<bool> _connect() async {
    if (_ble?.isConnected == true && _ble!.authed) return true;
    setState(() {
      _busy = true;
      _error = null;
      _step = 'Looking for puck ${widget.puck.puck} over Bluetooth…';
    });
    try {
      final b = await PuckBle.connect(widget.puck.puck, key: widget.puck.key.isNotEmpty ? widget.puck.key : null);
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
      if (!b.authed) {
        throw PuckException(b.pairing
            ? 'Puck ${widget.puck.puck} has a key this phone doesn\'t hold. Its pairing window is open, so "Set up again" from Your pucks makes it yours.'
            : 'Puck ${widget.puck.puck} doesn\'t answer to this phone\'s key (set up from another phone, or set up again since). '
                'Hold its button 6 seconds, then "Set up again" from Your pucks.');
      }
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
    if (b == null || !b.isConnected || !b.authed) {
      await _connect();
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
    if (!await _connect() || !mounted) return;
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

  // ---------------------------------------------------------------- tracks

  Future<void> _pull() async {
    if (!await _connect() || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
      _step = 'Asking what it has…';
    });
    try {
      final r = await PuckPull.all(_ble!, app.store, onStep: (s) {
        if (mounted) setState(() => _step = s);
      }, progress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      if (r.tracks > 0) app.tracksChanged();
      toast(context, r.sentence, error: !r.ok);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _listTracks() async {
    if (!await _connect() || !mounted) return;
    try {
      final l = await _ble!.tracks();
      if (mounted) setState(() => _tracks = l);
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    }
  }

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
      _progress = 0;
      _step = 'Downloading firmware ${f.version}…';
    });
    List<int> bin;
    try {
      bin = await Updates.instance.downloadPuckFirmware(f);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendly(e);
          _busy = false;
          _step = null;
          _progress = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!await _connect() || !mounted) {
      setState(() => _progress = null);
      return;
    }
    setState(() {
      _busy = true;
      _step = 'Sending ${(bin.length / 1024).round()} KB to the puck…';
    });
    try {
      await _ble!.flash(bin, progress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      await _link?.cancel();
      _link = null;
      setState(() {
        _step = null;
        _progress = null;
        _statusLive = false;
        _ble = null; // it restarts: whatever we were on is gone
      });
      await app.putMyPuck(widget.puck.copyWith(fw: f.version));
      if (mounted) toast(context, 'Firmware ${f.version} sent. The puck is restarting; give it a minute.');
    } catch (e) {
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = null;
          _progress = null;
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
    final pending = st?.pending ?? 0;
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
                          if (st.gpsFix >= 3) 'GPS ${st.sats} sats' else 'no GPS fix',
                          '$pending track${pending == 1 ? '' : 's'} waiting',
                        ].join(' · '),
                        style: dim,
                      ),
                    Text(
                      live
                          ? 'Connected over Bluetooth'
                          : st != null
                              ? 'Not connected now (as it was last time)'
                              : p.key.isNotEmpty
                                  ? 'Yours: talks to this phone only'
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
              if (live && st != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  _num(context, 'Speed', '${st.sogKn.toStringAsFixed(1)} kn'),
                  _num(context, 'Heel', '${st.heel.toStringAsFixed(0)}°'),
                  _num(context, 'Pitch', '${st.pitch.toStringAsFixed(0)}°'),
                ]),
              ],
              if (_step != null) ...[
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_step!, style: t.textTheme.bodyMedium)),
                ]),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _progress! > 0 ? _progress : null),
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
        const SectionLabel('Tracks'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(pending > 0 ? 'Get its tracks ($pending waiting)' : 'Get its tracks'),
              subtitle: const Text('Over Bluetooth, straight into Sessions; each one is cleared off the puck once it\'s here. '
                  'This happens by itself too whenever the puck is awake near the phone with WakeBack open.'),
              isThreeLine: true,
              enabled: !_busy,
              onTap: _busy ? null : _pull,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('What\'s on it'),
              subtitle: _tracks == null
                  ? const Text('Tap to list the tracks still on the puck.')
                  : Text(_tracks!.isEmpty
                      ? 'Nothing on it.'
                      : _tracks!.map((x) => '${x.name} (${(x.bytes / 1024).round()} KB${x.open ? ', recording' : ''})').join('\n')),
              enabled: !_busy,
              onTap: _busy ? null : _listTracks,
            ),
          ]),
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
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _do('Flipping the heel sign…', (b) => b.command('flip')),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Heel reads backwards'),
                ),
              ),
            ]),
          ),
        ),
        const SectionLabel('Recording and power'),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record, color: recording ? null : Colors.redAccent),
              title: Text(recording ? 'Stop recording' : 'Start recording'),
              subtitle: Text(recording ? 'Closes the track it\'s on now; only a finished track can be fetched.' : 'By hand. It starts by itself when the boat moves off anyway.'),
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
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Hint('The app downloads the new firmware from GitHub and sends it to the puck over Bluetooth (the puck just has to be awake, with the '
                  'phone next to it). The puck restarts; if the new firmware doesn\'t run properly it goes back to the old one by itself.'),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _num(BuildContext context, String label, String value) {
    final t = Theme.of(context);
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        Text(value, style: t.textTheme.titleMedium),
      ]),
    );
  }
}
