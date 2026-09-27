import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../demo/fake_race.dart';
import '../dock/pocket_dock.dart';
import '../dock/store.dart';
import '../widgets/common.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

/// Top-level for compute(): builds a demo race morning's files.
Map<String, String> _demoFiles(int t0ms) => demoDayFiles(DateTime.fromMillisecondsSinceEpoch(t0ms, isUtc: true));

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _ssid = TextEditingController(text: app.hotspotName);
  late final TextEditingController _pass = TextEditingController(text: app.hotspotPass);
  late final TextEditingController _name = TextEditingController(text: app.profileName);
  late final TextEditingController _email = TextEditingController(text: app.profileEmail);
  List<String> _ips = [];
  bool _makingDemo = false;

  @override
  void initState() {
    super.initState();
    _loadIps();
  }

  Future<void> _loadIps() async {
    final ips = await PocketDock.lanAddresses();
    if (mounted) setState(() => _ips = ips);
  }

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true, type: FileType.any);
    if (r == null) return;
    final ok = <String>[], bad = <String>[];
    for (final f in r.files) {
      try {
        final bytes = f.bytes;
        if (bytes == null) throw const DockError(400, 'couldn\'t read it');
        final res = await app.store.upload(f.name, bytes);
        ok.add('${res['session']}');
      } catch (e) {
        bad.add('${f.name}: $e');
      }
    }
    if (!mounted) return;
    final days = ok.toSet().join(', ');
    toast(
      context,
      [if (ok.isNotEmpty) 'Added ${ok.length} track${ok.length == 1 ? '' : 's'} to $days', if (bad.isNotEmpty) 'Skipped ${bad.join('; ')}'].join('. '),
      error: bad.isNotEmpty,
    );
  }

  Future<void> _addDemoDay() async {
    setState(() => _makingDemo = true);
    try {
      final now = DateTime.now().toUtc();
      final t0 = DateTime.utc(now.year, now.month, now.day, 10, 30);
      final files = await compute(_demoFiles, t0.millisecondsSinceEpoch);
      final day = '${DockStore.dayOf(t0)}_southport-sc'; // sessions are date + venue; the demo is sailed on the Marine Lake
      var n = 0;
      for (final e in files.entries) {
        if (await app.store.putTrack(day, e.key, utf8.encode(e.value))) n++;
      }
      if ((await app.store.getMeta(day)).isEmpty) await app.store.putMeta(day, demoMeta());
      if (mounted) {
        toast(context, n == 0 ? 'The demo day is already there ($day)' : 'Added demo day $day: 3 pucks + a phone GPX, two races, course laid. Open it from the sessions list.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t make demo day: $e', error: true);
    }
    if (mounted) setState(() => _makingDemo = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.demo]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Setup')),
        body: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 24), children: [
          // ------------------------------------------------ you
          const SectionLabel('You'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Your name', hintText: 'e.g. James', prefixIcon: Icon(Icons.person_outline)),
                  onChanged: (v) => app.profileName = v,
                ),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email (optional)', prefixIcon: Icon(Icons.alternate_email)),
                  onChanged: (v) => app.profileEmail = v,
                ),
                const SizedBox(height: 8),
                const Hint('Everything this phone records or imports is yours: your name goes on your boat, and it\'s '
                    'marked as sent by you when it syncs. Your email is how the server will know you (sign-in comes '
                    'next) and is never shown to other sailors.'),
              ]),
            ),
          ),

          // ------------------------------------------------ this phone as the dock
          const SectionLabel('This phone is the dock'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(app.dockError == null ? Icons.check_circle : Icons.error_outline,
                      color: app.dockError == null ? Colors.greenAccent : Colors.orangeAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(app.dockError == null ? 'Dock running on port ${app.dock.port}' : app.dockError!,
                        style: t.textTheme.titleSmall),
                  ),
                ]),
                const SizedBox(height: 10),
                const Hint('With no dock Pi, pucks upload to this phone instead — the same way they would to the dock:\n'
                    '1. Android Settings → Hotspot: set the name and password below and turn it on.\n'
                    '2. Keep WakeBack open (screen on is safest) while pucks are on their charging pads.\n'
                    '3. Pucks join the hotspot, check in and upload. Watch them on the viewer\'s Dock tab.'),
                const SizedBox(height: 12),
                TextField(
                  controller: _ssid,
                  decoration: const InputDecoration(labelText: 'Hotspot name', prefixIcon: Icon(Icons.wifi_tethering)),
                  onChanged: (v) => app.hotspotName = v,
                ),
                TextField(
                  controller: _pass,
                  decoration: const InputDecoration(labelText: 'Hotspot password', prefixIcon: Icon(Icons.key)),
                  onChanged: (v) => app.hotspotPass = v,
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: Text(
                      _ips.isEmpty
                          ? 'Phone address: turn the hotspot or WiFi on to see it'
                          : 'Phone address: ${_ips.map((ip) => 'http://$ip:${app.dock.port}').join('  ')}',
                      style: t.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(tooltip: 'Refresh', onPressed: _loadIps, icon: const Icon(Icons.refresh, size: 20)),
                ]),
                Row(children: [
                  const Text('Pucks in your fleet'),
                  const Spacer(),
                  IconButton(onPressed: app.fleet > 0 ? () => app.fleet = app.fleet - 1 : null, icon: const Icon(Icons.remove_circle_outline)),
                  Text('${app.fleet}', style: t.textTheme.titleMedium),
                  IconButton(onPressed: app.fleet < 16 ? () => app.fleet = app.fleet + 1 : null, icon: const Icon(Icons.add_circle_outline)),
                ]),
                const Hint('So pucks that have never checked in still get a row on the Dock page.'),
              ]),
            ),
          ),

          // ------------------------------------------------ tracks
          const SectionLabel('Tracks'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('Import tracks'),
              subtitle: const Text('Puck CSVs or phone/watch GPX — filed under the day they were sailed'),
              onTap: _import,
            ),
          ),

          // ------------------------------------------------ demo
          const SectionLabel('Try it without pucks'),
          Card(
            child: Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.science_outlined),
                title: const Text('Demo pucks'),
                subtitle: Text(app.demo.lastEvent ??
                    'Five pretend pucks check in to this phone every 3 s; P4 comes back from sailing after 20 s and uploads its session. See them on the viewer\'s Dock tab.'),
                isThreeLine: true,
                value: app.demo.running,
                onChanged: (on) => on ? app.demo.start() : app.demo.stop(),
              ),
              ListTile(
                leading: _makingDemo
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_chart),
                title: const Text('Add a demo race morning'),
                subtitle: const Text('Today 10:30: three pucks and a mate\'s phone, two races, marks and start/finish lines laid'),
                onTap: _makingDemo ? null : _addDemoDay,
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const Center(child: Hint('WakeBack app 0.2 · runs the dock API on this phone')),
        ]),
      ),
    );
  }
}
