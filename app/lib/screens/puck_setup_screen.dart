// Set up a puck from the app (roadmap stage 4): no browser, nothing to type on the puck.
//
//   1. Hotspot name + password (what the puck will join), the puck's number, auto-record.
//   2. Put the puck in setup mode (hold the button 6 s) and tap Connect: the phone joins
//      "wakeback-puck-N", reads the puck, pushes the settings and a key from your account, and tells the
//      puck to go and find the hotspot.
//   3. Turn the hotspot on. Done: the puck uploads to this phone after every sail, as you.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../puck/puck_wifi.dart';
import '../widgets/common.dart';
import 'guide_screen.dart';
import 'welcome_screen.dart';

class PuckSetupScreen extends StatefulWidget {
  /// Setting an existing puck up again? Its number, so the form starts there.
  final int? puck;
  const PuckSetupScreen({super.key, this.puck});
  @override
  State<PuckSetupScreen> createState() => _PuckSetupScreenState();
}

enum _Stage { form, connecting, done }

class _PuckSetupScreenState extends State<PuckSetupScreen> {
  late final TextEditingController _ssid = TextEditingController(text: app.hotspotName);
  late final TextEditingController _pass = TextEditingController(text: app.hotspotPass);
  late final TextEditingController _num = TextEditingController(text: '${widget.puck ?? _nextNumber()}');
  bool _autoRec = true, _showPass = false, _canJoin = false, _manual = false, _noKey = false, _keyFailed = false;
  _Stage _stage = _Stage.form;
  final _log = <String>[];
  String? _error;
  PuckStatus? _found;
  MyPuck? _result;
  bool _keyed = false;

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
    PuckWifi.supported().then((ok) {
      if (mounted) setState(() => _canJoin = ok);
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

  /// The whole thing, start to finish. Each step reports in the log; an error stops it with the reason.
  Future<void> _go({required bool manual, bool withoutKey = false}) async {
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
      _manual = manual;
      _log.clear();
      _error = null;
      _found = null;
      _noKey = withoutKey;
      _keyFailed = false;
    });
    try {
      // 1. a key from your account, while the phone still has the internet (once it's on the puck's WiFi it hasn't)
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

      // 2. onto the puck's WiFi
      if (manual) {
        _say('Looking for the puck at 192.168.4.1…');
      } else {
        _say('Joining the puck\'s WiFi (tap Connect when your phone asks)…');
        await PuckWifi.join();
        if (!mounted) return;
        _say('On the puck\'s WiFi.');
      }
      final api = PuckApi();
      PuckStatus st;
      try {
        st = await _retry(() => api.status(), tries: 4);
      } on PuckException catch (e) {
        throw PuckException('${e.message}\nIs the puck in setup mode? Hold its button for 6 s until it gives five quick blinks.');
      }
      if (!mounted) return;
      if (!st.isPuck) throw const PuckException('That network isn\'t a WakeBack puck.');
      setState(() => _found = st);
      _say('Found puck ${st.puck}, firmware ${st.fw.isEmpty ? '?' : st.fw}${st.batteryPct >= 0 ? ', battery ${st.batteryPct}%' : ''}.');

      // 3. settings over
      _say('Sending the hotspot name, password${key.isEmpty ? '' : ', your key'} and number $num…');
      await api.settings(puck: num, ssid: ssid, pass: pass, key: key, autoRec: _autoRec);
      if (!mounted) return;
      _say('Saved on the puck.');

      // 4. let it go and find the hotspot
      _say('Telling the puck to leave setup mode…');
      try {
        await api.done();
      } catch (_) {
        // it drops its WiFi as it leaves, so the reply often doesn't make it back: that's fine
      }
      await PuckWifi.leave();

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
      await PuckWifi.leave();
      if (mounted) setState(() => _error = friendly(e));
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
            Text('Put the puck in setup mode', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Hint('Hold its button for about 6 seconds until the light gives five quick blinks, then let go. (A brand-new puck, or one on a '
                'USB lead, is in setup mode already.) It puts up its own WiFi, "wakeback-puck-N", for a few minutes.'),
            const SizedBox(height: 12),
            if (_canJoin)
              FilledButton.icon(
                onPressed: () => _go(manual: false),
                icon: const Icon(Icons.wifi_find),
                label: const Text('Connect to the puck'),
              ),
            if (_canJoin) const SizedBox(height: 6),
            if (_canJoin)
              const Hint('Your phone will ask "Connect to device wakeback-puck-N?" — tap Connect. It keeps its mobile data meanwhile.'),
            if (!_canJoin) ...[
              const Hint('Join "wakeback-puck-N" in your phone\'s WiFi settings (tap "stay connected" if it moans about no internet), then come back and:'),
              const SizedBox(height: 8),
              FilledButton.icon(onPressed: () => _go(manual: true), icon: const Icon(Icons.check), label: const Text('I\'m on the puck\'s WiFi')),
            ] else ...[
              const SizedBox(height: 4),
              TextButton(onPressed: () => _go(manual: true), child: const Text('I\'ve already joined its WiFi myself')),
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
                FilledButton.icon(onPressed: () => _go(manual: _manual), icon: const Icon(Icons.refresh), label: const Text('Try again')),
                if (_keyFailed)
                  OutlinedButton.icon(
                    onPressed: () => _go(manual: _manual, withoutKey: true),
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
