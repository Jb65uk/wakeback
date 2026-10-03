import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../auth/auth_api.dart';
import '../demo/fake_race.dart';
import '../dock/pocket_dock.dart';
import '../dock/store.dart';
import '../widgets/boats.dart';
import '../widgets/common.dart';
import 'friends_section.dart';
import 'offline_maps.dart';
import 'update_card.dart';
import 'web_page.dart';
import 'welcome_screen.dart';

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
        appBar: AppBar(title: const Text('You')),
        body: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 24), children: [
          // ------------------------------------------------ demo banner
          if (app.demoMode)
            Card(
              color: t.colorScheme.primary.withValues(alpha: 0.15),
              child: ListTile(
                leading: Icon(Icons.science_outlined, color: t.colorScheme.primary),
                title: const Text('Demo mode'),
                subtitle: const Text('Pretend pucks and demo data. Leaving the demo wipes it all and takes you back to your own sailing.'),
                isThreeLine: true,
                trailing: FilledButton(onPressed: _exitDemo, child: const Text('Exit demo')),
              ),
            ),

          // ------------------------------------------------ you
          const SectionLabel('You'),
          if (app.signedIn) _accountCard(t) else _noAccountCard(t),
          if (app.signedIn) const FriendsSection(),
          const BoatsCard(),

          // ------------------------------------------------ tracks
          const SectionLabel('Tracks'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('Import tracks'),
              subtitle: const Text('GPX from a phone or watch, or puck CSVs'),
              onTap: _import,
            ),
          ),

          // ------------------------------------------------ maps for the lake
          const SectionLabel('Maps'),
          const OfflineMapsCard(),

          // ------------------------------------------------ about / updates
          const SectionLabel('About'),
          const AboutCard(),

          // ------------------------------------------------ advanced: pucks, server, demo (folded away)
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              leading: const Icon(Icons.tune),
              title: const Text('Advanced'),
              subtitle: const Text('Pucks and hotspot, server, demo'),
              shape: const Border(),
              childrenPadding: EdgeInsets.zero,
              children: [
          Padding(
            padding: EdgeInsets.zero,
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
                const Hint('Pucks upload to this phone over its hotspot: turn the hotspot on with the name and password below, and keep WakeBack open while pucks are on their pads.'),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerViewerPage(url: '${app.dock.localUrl}/dock', title: 'Pucks'))),
                    icon: const Icon(Icons.sensors, size: 18),
                    label: const Text('See your pucks'),
                  ),
                ),
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
              ]),
            ),
          ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server'),
                  subtitle: Text(app.serverUrl),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: _editServer,
                ),
                if (!app.demoMode)
                  ListTile(
                    leading: const Icon(Icons.science_outlined),
                    title: const Text('Try the demo'),
                    subtitle: const Text('Pretend pucks and a demo race, kept separate from your data'),
                    onTap: () async {
                      await app.setDemoMode(true);
                      if (context.mounted) toast(context, 'Demo mode on: add a demo race morning, or turn on Demo pucks');
                    },
                  ),
              ],
            ),
          ),

          // ------------------------------------------------ demo (only in demo mode)
          if (app.demoMode) const SectionLabel('Demo'),
          if (app.demoMode)
          Card(
            child: Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.science_outlined),
                title: const Text('Demo pucks'),
                subtitle: Text(app.demo.lastEvent ??
                    'Five pretend pucks check in to this phone every 3 s; P4 comes back from sailing after 20 s and uploads its session. See them under Advanced, See your pucks.'),
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
        ]),
      ),
    );
  }

  Future<void> _editServer() async {
    final c = TextEditingController(text: app.serverUrl);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WakeBack server'),
        content: TextField(controller: c, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(helperText: 'Only change this if you run your own server')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null) app.serverUrl = v;
  }

  Future<void> _exitDemo() async {
    if (!await confirm(context, 'Leave the demo?', 'The demo sessions and pretend pucks are deleted. Your own sailing is untouched.', ok: 'Exit demo', danger: true)) return;
    await app.setDemoMode(false);
    if (mounted) toast(context, 'Demo cleared');
  }

  Widget _accountCard(ThemeData t) {
    final a = app.account!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 22, backgroundColor: t.colorScheme.primary, child: Text(a.name.isEmpty ? '?' : a.name[0].toUpperCase(), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 18))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.name, style: t.textTheme.titleMedium),
                Text(a.email, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                if (a.isAdmin) Text('Admin', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary)),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          const Hint('Your sails sync to your account. Your email is never shown to other sailors.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(onPressed: _changePassword, icon: const Icon(Icons.key, size: 18), label: const Text('Change password')),
            OutlinedButton.icon(
              onPressed: () async {
                if (await confirm(context, 'Log out?', 'Your sessions stay on this phone. Sync needs you signed in.', ok: 'Log out')) await app.signOut();
              },
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Log out'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _noAccountCard(ThemeData t) {
    if (_name.text != app.profileName) _name.text = app.profileName; // e.g. after signing out
    return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Your name', hintText: 'e.g. James', prefixIcon: Icon(Icons.person_outline)),
              onChanged: (v) => app.profileName = v,
            ),
            const SizedBox(height: 8),
            const Hint('Sign in to sync your sails between devices and share them with friends.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () async {
                final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const WelcomeScreen(fromSetup: true)));
                if (ok == true && mounted) setState(() {});
              },
              icon: const Icon(Icons.login),
              label: const Text('Log in or create account'),
            ),
          ]),
        ),
      );
  }

  Future<void> _changePassword() async {
    final oldC = TextEditingController(), newC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: oldC, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
          TextField(controller: newC, obscureText: true, decoration: const InputDecoration(labelText: 'New password', helperText: 'At least 8 characters')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.auth.changePassword(oldC.text, newC.text);
      if (mounted) toast(context, 'Password changed');
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message, error: true);
    }
  }
}
