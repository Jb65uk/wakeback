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
              subtitle: Text(_tracks == null
                  ? 'Tap to list the tracks still on the puck.'
                  : _tracks!.isEmpty
                      ? 'Nothing on it.'
                      : '${_tracks!.length} track${_tracks!.length == 1 ? '' : 's'}. Tap one\'s bin to delete it without fetching.'),
              enabled: !_busy,
              onTap: _busy ? null : _listTracks,
            ),
            if (_tracks != null)
              for (final x in _tracks!)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 56, right: 8),
                  title: Text(x.name, style: t.textTheme.bodySmall),
                  subtitle: Text('${(x.bytes / 1024).round()} KB${x.open ? ' · recording now' : ''}'),
                  trailing: x.open
                      ? null
                      : IconButton(
                          tooltip: 'Delete from the puck',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: _busy ? null : () => _deleteTrack(x),
                        ),
                ),
            if (_tracks != null && _tracks!.isNotEmpty) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined, color: Colors.orangeAccent),
                title: const Text('Erase every track on the puck'),
                subtitle: const Text('Fetched or not. Can\'t be undone.'),
                enabled: !_busy,
                onTap: _busy ? null : _eraseAll,
              ),
            ],
          ]),
        ),
        const SectionLabel('On the boat'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (st != null) ...[
                Text(_calibrationLine(st), style: t.textTheme.bodyMedium),
                const SizedBox(height: 8),
              ],
              const Hint('With the puck clipped in and the boat sitting level, tell it so: heel and pitch then read 0 from here. Then say which way up it\'s mounted. '
                  'The twist from the bow it works out itself the first time you sail in a straight line.'),
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
              const SizedBox(height: 4),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                shape: const Border(),
                title: Text('Advanced', style: t.textTheme.titleSmall),
                children: [
                  if (st != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Twist ${st.twist.toStringAsFixed(0)}° ${st.twistLearned ? '(learned)' : '(not learned yet)'} · level offsets heel ${st.zeroHeel.toStringAsFixed(1)}°, pitch ${st.zeroPitch.toStringAsFixed(1)}°'
                        '${st.flip ? ' · heel sign flipped' : ''}',
                        style: dim,
                      ),
                    ),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _typeTwist,
                      icon: const Icon(Icons.rotate_right, size: 18),
                      label: const Text('Type the twist'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _do('Flipping the heel sign…', (b) => b.command('flip')),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Heel reads backwards'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _resetCal,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('Reset calibration'),
                    ),
                  ]),
                  const SizedBox(height: 4),
                ],
              ),
            ]),
          ),
        ),
        const SectionLabel('Recording and power'),
        Card(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Points a second while moving', style: t.textTheme.titleSmall),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 5, label: Text('5')),
                    ButtonSegment(value: 10, label: Text('10')),
                  ],
                  selected: {st?.recHz ?? 5},
                  showSelectedIcon: false,
                  onSelectionChanged: _busy || !live ? null : (v) => _do('Setting the rate…', (b) => b.settings(rate: v.first).then((_) => {'msg': '${v.first} a second while moving.'})),
                ),
                const SizedBox(height: 6),
                Hint(_rateHint(st?.recHz ?? 5)),
              ]),
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.play_circle_outline),
              title: const Text('Record on its own'),
              subtitle: Text('Starts when the boat moves off, stops after ${st?.stopMin ?? 10} minutes still.'),
              value: st?.autoRec ?? true,
              onChanged: _busy || !live ? null : (v) => _do(v ? 'Turning auto-record on…' : 'Turning auto-record off…', (b) => b.settings(autoRec: v).then((_) => {'msg': v ? 'Records on its own.' : 'Button only.'})),
            ),
            _minutes(
              context,
              'Sail is over after',
              'Minutes without moving 20 m before the track closes. Lunch ashore? Make it longer and the whole day stays one track.',
              const [5, 10, 20, 30],
              st?.stopMin ?? 10,
              (m) => _do('Setting it…', (b) => b.settings(stopMin: m).then((_) => {'msg': 'A sail ends after $m minutes still.'})),
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.power_settings_new),
              title: const Text('Switch itself off'),
              subtitle: Text('Sleeps after ${st?.sleepMin ?? 30} minutes still, off the pad. A press or the pad wakes it.'),
              value: st?.autoOff ?? true,
              onChanged: _busy || !live ? null : (v) => _do(v ? 'Turning auto-off on…' : 'Turning auto-off off…', (b) => b.settings(autoOff: v).then((_) => {'msg': v ? 'Sleeps by itself.' : 'Stays awake until you hold the button.'})),
            ),
            if (st?.autoOff ?? true)
              _minutes(
                context,
                'Sleep after',
                'Minutes still before it switches itself off.',
                const [15, 30, 60, 120],
                st?.sleepMin ?? 30,
                (m) => _do('Setting it…', (b) => b.settings(sleepMin: m).then((_) => {'msg': 'Sleeps after $m minutes still.'})),
              ),
            const Divider(height: 1),
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

  Future<void> _deleteTrack(PuckTrack x) async {
    if (!await confirm(context, 'Delete ${x.name} from the puck?', 'It hasn\'t been fetched. Gone for good.', ok: 'Delete', danger: true)) return;
    await _do('Deleting…', (b) => b.done(x.name).then((_) => {'msg': 'Deleted.'}));
    await _listTracks();
  }

  Future<void> _eraseAll() async {
    if (!await confirm(context, 'Erase every track on puck ${widget.puck.puck}?', 'Fetched or not, all of them. Can\'t be undone.', ok: 'Erase', danger: true)) return;
    await _do('Erasing…', (b) => b.command('erase'));
    await _listTracks();
  }

  Future<void> _typeTwist() async {
    final c = TextEditingController(text: _status?.twist.toStringAsFixed(0) ?? '0');
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mounting twist'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Hint('Degrees the puck\'s lid arrow points clockwise of the bow. 0 = arrow at the bow. It normally learns this by itself on the first straight leg; only type it if that\'s not happening.'),
          const SizedBox(height: 8),
          TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true), decoration: const InputDecoration(suffixText: '°'), autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: const Text('Set')),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await _do('Setting the twist…', (b) => b.setTwist(v).then((_) => {'msg': 'Twist ${v.toStringAsFixed(0)}°.'}));
  }

  Future<void> _resetCal() async {
    if (!await confirm(context, 'Reset calibration?', 'Level, twist, heel sign and which way up all go back to unknown. It relearns which way up and the twist by itself; set level again with the boat sat level.', ok: 'Reset', danger: true)) return;
    await _do('Resetting…', (b) => b.calReset().then((_) => {'msg': 'Calibration cleared.'}));
  }

  static String _calibrationLine(PuckStatus st) {
    final where = switch (st.orientation) { 'deck' => 'Mounted on deck', 'thwart' => 'Under the thwart', _ => 'Which way up: not known yet' };
    final twist = st.twistLearned ? 'twist ${st.twist.toStringAsFixed(0)}° learned' : 'twist not learned yet (sail a straight leg)';
    final mag = switch (st.mag) { 3 => 'compass good', 2 => 'compass fair', _ => 'compass poor (turn it over a few times)' };
    return '$where · $twist · $mag';
  }

  Widget _minutes(BuildContext context, String title, String hint, List<int> choices, int current, void Function(int) onPick) {
    final t = Theme.of(context);
    final live = _ble?.isConnected == true && _statusLive;
    final set = choices.contains(current) ? {current} : {choices.first};
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          segments: [for (final m in choices) ButtonSegment(value: m, label: Text('$m min'))],
          selected: set,
          showSelectedIcon: false,
          onSelectionChanged: _busy || !live ? null : (v) => onPick(v.first),
        ),
        const SizedBox(height: 4),
        Hint(hint),
      ]),
    );
  }

  static String _rateHint(int hz) => switch (hz) {
        10 => 'Smoothest replay; about 9 hours of sailing fits on the puck.',
        5 => 'Plenty for a dinghy; about 18 hours fits on the puck.',
        2 => 'Enough for the track and the numbers; about 45 hours fits.',
        _ => 'Just the track; days of sailing fit. Always 1 a second while still.',
      };

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
