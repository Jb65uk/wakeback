// Set up a puck from the app: nothing to type on the puck, no WiFi anywhere.
//
//   1. The puck's number, and whether it records on its own.
//   2. With the puck awake (on the pad, or press its button) tap Connect: the phone finds it over Bluetooth,
//      and hands it a key from your account. From then on the puck only talks to a phone that holds that key.
//      A puck that already belongs to someone (or to you on another phone) needs its pairing window open:
//      hold its button 6 s (five quick blinks).
//   3. Done. Put it in the boat; after a sail, put it on the pad with WakeBack open and the tracks come over.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../puck/puck_ble.dart';
import '../widgets/common.dart';
import '../widgets/puck_picker.dart';
import 'guide_screen.dart';
import 'welcome_screen.dart';

class PuckSetupScreen extends StatefulWidget {
  /// Setting an existing puck up again? Its number, so the form starts there.
  final int? puck;

  /// A puck just heard nearby (Your pucks → Find pucks nearby): its current number, to start from.
  final PuckSeen? nearby;
  const PuckSetupScreen({super.key, this.puck, this.nearby});
  @override
  State<PuckSetupScreen> createState() => _PuckSetupScreenState();
}

enum _Stage { form, connecting, done }

class _PuckSetupScreenState extends State<PuckSetupScreen> {
  late final TextEditingController _num = TextEditingController(text: '${widget.puck ?? widget.nearby?.puck ?? _nextNumber()}');
  bool _autoRec = true, _canBle = true, _noKey = false, _keyFailed = false;
  _Stage _stage = _Stage.form;
  final _log = <String>[];
  String? _error;
  MyPuck? _result;
  bool _keyed = false;
  int _tracksWaiting = 0;

  /// The puck picked from the nearby list, if any: Connect goes straight to it (whatever number it has now).
  PuckSeen? _target;

  /// A key the server issued this time round, and the puck number it's for: Try again reuses it rather
  /// than asking for another (each new key revokes the last).
  String _key = '';
  int _keyId = 0, _keyFor = 0;

  static int _nextNumber() {
    final have = app.myPucks.map((p) => p.puck).toSet();
    var n = 1;
    while (have.contains(n)) {
      n++;
    }
    return n;
  }

  @override
  void initState() {
    super.initState();
    _target = widget.nearby;
    PuckBle.available().then((ok) {
      if (mounted) setState(() => _canBle = ok);
    });
  }

  @override
  void dispose() {
    _num.dispose();
    super.dispose();
  }

  String? _formProblem() {
    final n = int.tryParse(_num.text.trim());
    if (n == null || n < 1 || n > 99) return 'Puck number is 1 to 99.';
    return null;
  }

  void _say(String s) {
    if (mounted) setState(() => _log.add(s));
  }

  /// "Find pucks nearby": scan, let the user pick one, and put its number in the box.
  Future<void> _findNearby() async {
    final p = await pickPuckNearby(context, title: 'Which puck?');
    if (p == null || !mounted) return;
    setState(() {
      _target = p;
      if (widget.puck == null) _num.text = '${p.puck}';
    });
    toast(context, 'Puck ${p.puck} is nearby (${p.signal}). Tap Connect to the puck when you\'re ready.');
  }

  /// The whole thing, start to finish. Each step reports in the log; an error stops it with the reason.
  Future<void> _go({bool withoutKey = false}) async {
    final problem = _formProblem();
    if (problem != null) {
      toast(context, problem, error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    final num = int.parse(_num.text.trim());
    setState(() {
      _stage = _Stage.connecting;
      _log.clear();
      _error = null;
      _noKey = withoutKey;
      _keyFailed = false;
    });
    PuckBle? ble;
    PuckBle.busy = true;
    try {
      // 1. reach the puck
      ble = await _overBluetooth(num);
      if (!mounted) return;
      if (ble == null) {
        throw const PuckException('Not heard over Bluetooth. Is the puck awake (on the pad, or press its button) and the phone next to it?');
      }
      final existing = app.myPucks.where((p) => p.puck == widget.puck || p.puck == num).firstOrNull;

      // 2. a key: the one the puck already answers to (ours), else a fresh one from your account
      String key = '';
      int keyId = 0;
      if (ble.locked && ble.authed && existing != null && existing.key.isNotEmpty) {
        key = existing.key;
        keyId = existing.keyId;
        _say('It already answers to this phone\'s key: keeping it (its tracks stay on it).');
      } else if (ble.locked && !ble.authed && !ble.pairing) {
        throw const PuckException('This puck belongs to someone (or to you on another phone) and its pairing window is shut. '
            'Hold its button for 6 seconds until it gives five quick blinks, then tap Try again. Giving it a new key erases the tracks on it.');
      } else if (withoutKey) {
        _say('Setting up without an account key: anyone\'s app can talk to the puck until you set it up again with one.');
      } else if (app.signedIn && !app.demoMode) {
        if (_key.isNotEmpty && _keyFor == num) {
          key = _key;
          keyId = _keyId;
          _say('Using the key your account issued a moment ago for puck $num.');
        } else {
          _say('Asking your account for a key for puck $num…');
          try {
            final k = await app.auth.issuePuckKey(num);
            if (!mounted) return;
            key = _key = k.key;
            keyId = _keyId = k.info.id;
            _keyFor = num;
            _say('Got it. The puck will be yours: ${app.account!.name}.');
          } catch (e) {
            if (!mounted) return;
            setState(() => _keyFailed = true);
            throw PuckException('Couldn\'t get a key from the server: ${friendly(e)}\nCheck your signal and try again, or continue without a key for now.');
          }
        }
      } else {
        _say(app.demoMode ? 'Demo mode: no account key.' : 'Not signed in: no account key. The puck stays open to any phone until you set it up with one.');
      }

      // 3. settings over
      _say('Sending the number $num${key.isEmpty ? '' : ' and your key'}…');
      await ble.settings(puck: num, key: key, autoRec: _autoRec);
      if (!mounted) return;
      _say('Saved on the puck.');
      PuckStatus? st;
      try {
        st = await ble.status();
        _say('Puck $num, firmware ${st.fw.isEmpty ? '?' : st.fw}${st.batteryPct >= 0 ? ', battery ${st.batteryPct}%' : ''}.');
      } catch (_) {}
      await ble.disconnect();
      ble = null;

      final mine = MyPuck(puck: num, keyId: keyId, setUpMs: DateTime.now().millisecondsSinceEpoch, fw: st?.fw ?? '', key: key);
      await app.putMyPuck(mine);
      if (widget.puck != null && widget.puck != num) {
        // renumbered: the old number's key would otherwise stay live on the server
        final old = app.myPucks.where((p) => p.puck == widget.puck).firstOrNull;
        await app.removeMyPuck(widget.puck!);
        if (old != null && old.keyId > 0 && old.keyId != keyId && app.signedIn) {
          try {
            await app.auth.revokePuckKey(old.keyId);
          } catch (_) {}
        }
      }
      if (!mounted) return;
      setState(() {
        _result = mine;
        _keyed = key.isNotEmpty;
        _tracksWaiting = st?.pending ?? 0;
        _stage = _Stage.done;
      });
    } catch (e) {
      await ble?.disconnect();
      if (mounted) setState(() => _error = friendly(e));
    } finally {
      PuckBle.busy = false;
    }
  }

  /// Find the puck over Bluetooth and connect. The one picked from the nearby list if there was one; else
  /// whichever puck nearby already has the number in the box; else the only puck nearby; else ask.
  /// Null when Bluetooth is off or no puck is heard.
  Future<PuckBle?> _overBluetooth(int num) async {
    if (!await PuckBle.available()) {
      _say('Bluetooth is off, or this phone hasn\'t got it.');
      return null;
    }
    var target = _target;
    if (target == null) {
      _say('Listening for pucks nearby over Bluetooth…');
      final heard = <int, PuckSeen>{};
      try {
        await for (final p in PuckBle.scan(timeout: const Duration(seconds: 8))) {
          heard[p.puck] = p;
          if (p.puck == num && (p.mine || p.unpaired)) break; // the one we're after
        }
      } catch (e) {
        _say(friendly(e));
        return null;
      }
      if (!mounted) return null;
      if (heard.containsKey(num)) {
        target = heard[num];
      } else if (heard.length == 1) {
        target = heard.values.first;
        _say('Heard puck ${heard.keys.first} (it becomes puck $num).');
      } else if (heard.length > 1) {
        _say('Heard ${heard.length} pucks. Which one is this?');
        target = await pickPuckNearby(context, title: 'Which puck is this?');
        if (!mounted) return null;
        if (target == null) throw const PuckException('No puck picked. Tap Try again and choose the puck to set up.');
      } else {
        return null;
      }
      _target = target;
    }
    _say('Connecting to puck ${target!.puck} over Bluetooth…');
    try {
      final b = await PuckBle.connectTo(target);
      _say(b.locked ? (b.authed ? 'Connected: it\'s yours.' : b.pairing ? 'Connected: its pairing window is open.' : 'Connected: it has someone\'s key.') : 'Connected: it has no key yet.');
      return b;
    } on PuckException catch (e) {
      _say(e.message);
      _target = null; // it may have gone to sleep: look again next time
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.puck == null ? 'Set up a puck' : 'Set up puck ${widget.puck} again'), actions: [
        IconButton(
          tooltip: 'Guide',
          icon: const Icon(Icons.help_outline),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GuideScreen(open: GuideTopic.puck))),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: switch (_stage) {
          _Stage.form => _form(context),
          _Stage.connecting => _progress(context),
          _Stage.done => _finished(context),
        },
      ),
    );
  }

  // ------------------------------------------------------------------ 1. the form

  List<Widget> _form(BuildContext context) {
    final t = Theme.of(context);
    return [
      const SectionLabel('1. This puck'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _num,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Puck number', prefixIcon: Icon(Icons.tag)),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Hint('Its name in the tracks. Each of your pucks needs its own.')),
            ]),
            if (_target != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Hint('Puck ${_target!.puck} is nearby (${_target!.signal}).${_target!.puck != int.tryParse(_num.text.trim()) ? ' It becomes puck ${_num.text.trim()}.' : ''}'),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Record on its own'),
              subtitle: const Text('Starts when the boat moves off, stops when it\'s still. Off = tap the button to record.'),
              value: _autoRec,
              onChanged: (v) => setState(() => _autoRec = v),
            ),
            if (app.signedIn && !app.demoMode)
              Hint('Signed in as ${app.account!.name}: the puck gets a key tied to your account. Only your phone can talk to it, and its sails are yours on every device and in the league.')
            else if (app.demoMode)
              const Hint('Demo mode: the puck gets no account key.')
            else ...[
              const Hint('Not signed in: the puck gets no key, so any phone with WakeBack could talk to it. Log in first to make it yours.'),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const WelcomeScreen(fromSetup: true)));
                    if (ok == true && mounted) setState(() {});
                  },
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('Log in'),
                ),
              ),
            ],
          ]),
        ),
      ),
      const SectionLabel('2. Connect to the puck'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Make sure the puck is awake', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Hint('On the pad, or press its button once (the light blinks). The phone talks to it over Bluetooth: nothing to hold, no WiFi to join. '
                'Keep the phone next to it.'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 4, children: [
              FilledButton.icon(
                onPressed: _canBle ? () => _go() : null,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Connect to the puck'),
              ),
              OutlinedButton.icon(
                onPressed: _findNearby,
                icon: const Icon(Icons.radar, size: 18),
                label: const Text('Find pucks nearby'),
              ),
            ]),
            if (!_canBle) ...[
              const SizedBox(height: 6),
              const Hint('Bluetooth looks to be off. Turn it on: it\'s the only way to talk to a puck.'),
            ],
            const SizedBox(height: 14),
            Text('A puck that already has an owner', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Hint('A brand-new puck takes a key from anyone. One that\'s been set up before (by you on another phone, or by someone else) only '
                'takes a new key while its pairing window is open: hold its button for about 6 seconds until the light gives five quick blinks, '
                'then let go and tap Connect. A new key erases the tracks still on it.'),
          ]),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------------ 2. doing it

  List<Widget> _progress(BuildContext context) {
    final t = Theme.of(context);
    return [
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (_error == null) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) else const Icon(Icons.error_outline, color: Colors.orangeAccent),
              const SizedBox(width: 10),
              Expanded(child: Text(_error == null ? 'Setting up…' : 'Didn\'t finish', style: t.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 10),
            for (final l in _log)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 3), child: Icon(Icons.check, size: 16, color: Colors.greenAccent)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(l, style: t.textTheme.bodyMedium)),
                ]),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.red.shade900.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8)),
                child: Text(_error!, style: t.textTheme.bodyMedium),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 4, children: [
                FilledButton.icon(onPressed: () => _go(), icon: const Icon(Icons.refresh), label: const Text('Try again')),
                if (_keyFailed)
                  OutlinedButton.icon(
                    onPressed: () => _go(withoutKey: true),
                    icon: const Icon(Icons.key_off, size: 18),
                    label: const Text('Continue without a key'),
                  ),
                OutlinedButton(onPressed: () => setState(() => _stage = _Stage.form), child: const Text('Back')),
              ]),
            ],
          ]),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------------ 3. done

  List<Widget> _finished(BuildContext context) {
    final t = Theme.of(context);
    final r = _result!;
    return [
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.check_circle, color: Colors.greenAccent, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text('Puck ${r.puck} is set up', style: t.textTheme.titleLarge)),
            ]),
            const SizedBox(height: 8),
            Text(
              _keyed ? 'It\'s yours: only this phone talks to it, and its sails go up as ${app.account?.name ?? 'you'}.' : 'It\'s ready, with no account key.',
              style: t.textTheme.bodyMedium,
            ),
            if (!_keyed && _noKey) ...[
              const SizedBox(height: 6),
              const Hint('No account key this time. When you\'re back in signal, "Set up again" from Your pucks gives it one.'),
            ],
            if (_tracksWaiting > 0) ...[
              const SizedBox(height: 6),
              Hint('It has $_tracksWaiting track${_tracksWaiting == 1 ? '' : 's'} waiting: they come over by themselves in a minute while WakeBack is open, or tap the puck under Your pucks → Get its tracks.'),
            ],
          ]),
        ),
      ),
      const SectionLabel('From here'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Hint('Clip it in the boat. It records by itself when the boat moves off and stops when you\'re done. Afterwards, put it on the pad '
                '(or press its button) with WakeBack open and the phone nearby: the tracks come over on their own and land in Sessions. '
                'The first time it\'s in the boat, tap it under Your pucks and set "Boat is level" and which way up it\'s mounted.'),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft, child: FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))),
          ]),
        ),
      ),
    ];
  }
}
