// Set up a puck from the app (roadmap stage 4): no browser, nothing to type on the puck.
//
//   1. Hotspot name + password (what the puck will join), the puck's number, auto-record.
//   2. With the puck awake (on the pad, or press its button) tap Connect: the phone finds it over Bluetooth,
//      reads it, pushes the settings and a key from your account, and tells the puck to go and find the hotspot.
//      No Bluetooth, or the puck isn't heard? The old way still works: the puck's own setup WiFi
//      ("wakeback-puck-N", hold the button 6 s), joined from the app or by hand.
//   3. Turn the hotspot on. Done: the puck uploads to this phone after every sail, as you.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../puck/puck_ble.dart';
import '../puck/puck_wifi.dart';
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

/// How to reach the puck: Bluetooth (the normal way), its setup WiFi joined by the app, or the user has
/// already joined that WiFi by hand.
enum _Route { ble, wifi, wifiManual }

class _PuckSetupScreenState extends State<PuckSetupScreen> {
  late final TextEditingController _ssid = TextEditingController(text: app.hotspotName);
  late final TextEditingController _pass = TextEditingController(text: app.hotspotPass);
  late final TextEditingController _num = TextEditingController(text: '${widget.puck ?? widget.nearby?.puck ?? _nextNumber()}');
  bool _autoRec = true, _showPass = false, _canJoin = false, _canBle = true, _noKey = false, _keyFailed = false;
  _Route _route = _Route.ble;
  _Stage _stage = _Stage.form;
  final _log = <String>[];
  String? _error;
  PuckStatus? _found;
  MyPuck? _result;
  bool _keyed = false;

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
    PuckWifi.supported().then((ok) {
      if (mounted) setState(() => _canJoin = ok);
    });
    PuckBle.available().then((ok) {
      if (mounted) setState(() => _canBle = ok);
    });
  }

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    _num.dispose();
    PuckWifi.leave();
    super.dispose();
  }

  String? _formProblem() {
    final ssid = _ssid.text.trim();
    if (ssid.isEmpty || ssid.length > 32) return 'Give the hotspot a name (up to 32 characters).';
    if (_pass.text.length < 8 || _pass.text.length > 63) return 'The hotspot password needs 8 to 63 characters (Android won\'t allow shorter).';
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
  Future<void> _go({required _Route route, bool withoutKey = false}) async {
    final problem = _formProblem();
    if (problem != null) {
      toast(context, problem, error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    final ssid = _ssid.text.trim(), pass = _pass.text, num = int.parse(_num.text.trim());
    app.hotspotName = ssid;
    app.hotspotPass = pass;
    setState(() {
      _stage = _Stage.connecting;
      _route = route;
      _log.clear();
      _error = null;
      _found = null;
      _noKey = withoutKey;
      _keyFailed = false;
    });
    PuckBle? ble;
    try {
      // 1. a key from your account, while the phone still has the internet (on the puck's WiFi it hasn't)
      String key = '';
      int keyId = 0;
      if (withoutKey) {
        _say('Setting up without an account key: the puck will upload to this phone only. Set it up again later to give it one.');
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
            _say('Got it. The puck will upload as ${app.account!.name}.');
          } catch (e) {
            if (!mounted) return;
            setState(() => _keyFailed = true);
            throw PuckException('Couldn\'t get a key from the server: ${friendly(e)}\nCheck your signal and try again, or continue without a key (the puck still uploads to this phone, just not as you on the server).');
          }
        }
      } else {
        _say(app.demoMode ? 'Demo mode: no account key.' : 'Not signed in: no account key. The puck will still upload to this phone.');
      }

      // 2. reach the puck: Bluetooth first, its setup WiFi if that doesn't work out
      PuckStatus st;
      var via = route;
      if (route == _Route.ble) {
        ble = await _overBluetooth(num);
        if (!mounted) return;
        if (ble == null) {
          if (!_canJoin) {
            throw const PuckException('Not heard over Bluetooth. Is the puck awake (on the pad, or press its button)? Or join its setup WiFi '
                '"wakeback-puck-N" in your phone\'s settings (hold its button 6 s: five quick blinks) and tap "I\'ve already joined its WiFi myself".');
          }
          _say('Not heard over Bluetooth. Trying the puck\'s own WiFi instead: hold its button 6 s (five quick blinks), then tap Connect when your phone asks…');
          via = _Route.wifi;
        }
      }
      if (ble != null) {
        st = await ble.status();
      } else {
        if (via == _Route.wifiManual) {
          _say('Looking for the puck at 192.168.4.1…');
        } else {
          _say('Joining the puck\'s WiFi (tap Connect when your phone asks)…');
          await PuckWifi.join();
          if (!mounted) return;
          _say('On the puck\'s WiFi.');
        }
        final api = PuckApi();
        try {
          st = await _retry(() => api.status(), tries: 4);
        } on PuckException catch (e) {
          throw PuckException('${e.message}\nIs the puck in setup mode? Hold its button for 6 s until it gives five quick blinks.');
        }
      }
      if (!mounted) return;
      if (!st.isPuck) throw const PuckException('That isn\'t a WakeBack puck.');
      setState(() => _found = st);
      _say('Found puck ${st.puck}, firmware ${st.fw.isEmpty ? '?' : st.fw}${st.batteryPct >= 0 ? ', battery ${st.batteryPct}%' : ''}.');

      // 3. settings over
      _say('Sending the hotspot name, password${key.isEmpty ? '' : ', your key'} and number $num…');
      if (ble != null) {
        await ble.settings(puck: num, ssid: ssid, pass: pass, key: key, autoRec: _autoRec);
      } else {
        await PuckApi().settings(puck: num, ssid: ssid, pass: pass, key: key, autoRec: _autoRec);
      }
      if (!mounted) return;
      _say('Saved on the puck.');

      // 4. let it go and find the hotspot
      if (ble != null) {
        _say('Telling the puck to go and find the hotspot…');
        try {
          await ble.uploadNow();
        } catch (_) {
          // it's saved either way; it looks for the hotspot by itself after a sail
        }
        await ble.disconnect();
        ble = null;
      } else {
        _say('Telling the puck to leave setup mode…');
        try {
          await PuckApi().done();
        } catch (_) {
          // it drops its WiFi as it leaves, so the reply often doesn't make it back: that's fine
        }
        await PuckWifi.leave();
      }

      final mine = MyPuck(puck: num, keyId: keyId, setUpMs: DateTime.now().millisecondsSinceEpoch, fw: st.fw, hotspot: ssid);
      await app.putMyPuck(mine);
      if (widget.puck != null && widget.puck != num) {
        // renumbered: the old number's key would otherwise stay live on the server
        final old = app.myPucks.where((p) => p.puck == widget.puck).firstOrNull;
        await app.removeMyPuck(widget.puck!);
        if (old != null && old.keyId > 0 && app.signedIn) {
          try {
            await app.auth.revokePuckKey(old.keyId);
          } catch (_) {}
        }
      }
      if (!mounted) return;
      setState(() {
        _result = mine;
        _keyed = key.isNotEmpty;
        _stage = _Stage.done;
      });
    } catch (e) {
      await ble?.disconnect();
      await PuckWifi.leave();
      if (mounted) setState(() => _error = friendly(e));
    }
  }

  /// Find the puck over Bluetooth and connect. The one picked from the nearby list if there was one; else
  /// whichever puck nearby already has the number in the box; else the only puck nearby; else ask. Null
  /// when Bluetooth is off or no puck is heard (the caller falls back to WiFi).
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
          if (p.puck == num) break; // the one we're after
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
      _say('Connected.');
      return b;
    } on PuckException catch (e) {
      _say(e.message);
      _target = null; // it may have gone to sleep: look again next time
      return null;
    }
  }

  Future<T> _retry<T>(Future<T> Function() f, {int tries = 3}) async {
    Object? last;
    for (var i = 0; i < tries; i++) {
      try {
        return await f();
      } catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
    throw last!;
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
      const SectionLabel('1. The hotspot the puck will join'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Hint('After a sail the puck looks for this phone\'s hotspot and uploads to WakeBack. Make the phone\'s hotspot match these '
                'exactly (Settings → Hotspot), on the 2.4 GHz band — the puck can\'t see 5 GHz.'),
            const SizedBox(height: 8),
            TextField(
              controller: _ssid,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Hotspot name', prefixIcon: Icon(Icons.wifi_tethering)),
            ),
            TextField(
              controller: _pass,
              obscureText: !_showPass,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Hotspot password',
                prefixIcon: const Icon(Icons.key),
                helperText: '8 to 63 characters, the same as on the phone',
                suffixIcon: IconButton(
                  icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
              ),
            ),
          ]),
        ),
      ),
      const SectionLabel('2. This puck'),
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
              const Expanded(child: Hint('Its name in the tracks and on the Dock page. Each of your pucks needs its own.')),
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
              Hint('Signed in as ${app.account!.name}: the puck gets a key tied to your account, so its sails are yours on every device and in the league.')
            else if (app.demoMode)
              const Hint('Demo mode: the puck gets no account key.')
            else ...[
              const Hint('Not signed in: the puck will upload to this phone only. Log in first if you want its sails on your account.'),
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
      const SectionLabel('3. Connect to the puck'),
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
                onPressed: () => _go(route: _Route.ble),
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
              const Hint('Bluetooth looks to be off: turn it on, or the app will try the puck\'s WiFi instead.'),
            ],
            const SizedBox(height: 14),
            Text('If the puck isn\'t heard', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Hint('The old way: hold the puck\'s button for about 6 seconds until the light gives five quick blinks, then let go. It puts up its own '
                'WiFi, "wakeback-puck-N", for a few minutes.'),
            const SizedBox(height: 6),
            if (_canJoin)
              Wrap(spacing: 8, runSpacing: 4, children: [
                OutlinedButton.icon(
                  onPressed: () => _go(route: _Route.wifi),
                  icon: const Icon(Icons.wifi_find, size: 18),
                  label: const Text('Use its WiFi'),
                ),
                TextButton(onPressed: () => _go(route: _Route.wifiManual), child: const Text('I\'ve already joined its WiFi myself')),
              ])
            else ...[
              const Hint('Join "wakeback-puck-N" in your phone\'s WiFi settings (tap "stay connected" if it moans about no internet), then come back and:'),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: () => _go(route: _Route.wifiManual), icon: const Icon(Icons.check, size: 18), label: const Text('I\'m on the puck\'s WiFi')),
            ],
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
                FilledButton.icon(onPressed: () => _go(route: _route), icon: const Icon(Icons.refresh), label: const Text('Try again')),
                if (_keyFailed)
                  OutlinedButton.icon(
                    onPressed: () => _go(route: _route, withoutKey: true),
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
              _keyed
                  ? 'It will join hotspot "${r.hotspot}" and upload to this phone as ${app.account?.name ?? 'you'}.'
                  : 'It will join hotspot "${r.hotspot}" and upload to this phone.',
              style: t.textTheme.bodyMedium,
            ),
            if (!_keyed && _noKey) ...[
              const SizedBox(height: 6),
              const Hint('No account key this time. When you\'re back in signal, "Set up again" from Your pucks gives it one.'),
            ],
            if (_found != null && _found!.tracks > 0) ...[
              const SizedBox(height: 6),
              Hint('It has ${_found!.tracks} track${_found!.tracks == 1 ? '' : 's'} waiting: they\'ll come over as soon as it finds the hotspot.'),
            ],
          ]),
        ),
      ),
      const SectionLabel('Now'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Turn your hotspot on', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            Hint('Make the phone\'s hotspot match exactly, on 2.4 GHz. Turn off "switch hotspot off automatically" so it\'s still up when '
                'you come ashore. Keep WakeBack open while the puck uploads (it only listens while it\'s on screen).'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('Name: ${r.hotspot}', style: t.textTheme.bodyMedium)),
              IconButton(tooltip: 'Copy', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(context, r.hotspot)),
            ]),
            Row(children: [
              Expanded(child: Text('Password: ${app.hotspotPass}', style: t.textTheme.bodyMedium)),
              IconButton(tooltip: 'Copy', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(context, app.hotspotPass)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  if (!await PuckWifi.hotspotSettings() && context.mounted) toast(context, 'Find it under Settings → Network → Hotspot');
                },
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Open hotspot settings'),
              ),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
            ]),
            const SizedBox(height: 10),
            const Hint('Then: the puck records on its own when the boat moves off, and after a sail it tries the hotspot every minute for 15 '
                'minutes, then whenever it\'s on the pad. You → Pucks → See them check in shows it arriving.'),
          ]),
        ),
      ),
    ];
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) toast(context, 'Copied');
  }
}
