// "Your pucks" on the You tab: the pucks set up from this phone, set up another, set one up again, forget one.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../auth/auth_api.dart';
import '../widgets/common.dart';
import '../widgets/format.dart';
import '../widgets/puck_picker.dart';
import 'puck_screen.dart';
import 'puck_setup_screen.dart';

class PucksCard extends StatelessWidget {
  const PucksCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pucks = app.myPucks;
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          leading: const Icon(Icons.sensors),
          title: const Text('Your pucks'),
          subtitle: Text(pucks.isEmpty
              ? 'Set a puck up from here: it then records every sail by itself and hands the tracks to this phone over Bluetooth.'
              : app.watcher.lastEvent ?? 'Tracks come over by themselves whenever a puck is awake near the phone with WakeBack open.'),
          isThreeLine: true,
        ),
        for (final p in pucks)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 16, backgroundColor: t.colorScheme.primary, child: Text('${p.puck}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700))),
            title: Text('Puck ${p.puck}'),
            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PuckScreen(puck: p))),
            subtitle: Text([
              if (p.fw.isNotEmpty) 'firmware ${p.fw}',
              p.key.isNotEmpty ? 'yours' : p.keyId > 0 ? 'key not on this phone — Set up again' : 'no account key',
              if (p.setUpMs > 0) 'set up ${dayMonth(p.setUpMs)}',
            ].join(' · ')),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => v == 'open'
                  ? Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PuckScreen(puck: p)))
                  : v == 'again'
                      ? _setUp(context, p.puck)
                      : _forget(context, p),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'open', child: Text('Tracks, settings and firmware')),
                PopupMenuItem(value: 'again', child: Text('Set up again')),
                PopupMenuItem(value: 'forget', child: Text('Forget this puck')),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.icon(onPressed: () => _setUp(context, null), icon: const Icon(Icons.add, size: 18), label: Text(pucks.isEmpty ? 'Set up a puck' : 'Set up another')),
            OutlinedButton.icon(
              onPressed: () => _findNearby(context),
              icon: const Icon(Icons.bluetooth_searching, size: 18),
              label: const Text('Find pucks nearby'),
            ),
            if (pucks.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => app.watcher.tick(),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Check for tracks now'),
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _setUp(BuildContext context, int? puck) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PuckSetupScreen(puck: puck)));
  }

  /// Listen over Bluetooth for pucks that are awake nearby; one that isn't in the list yet can be set up
  /// from here, with its number filled in.
  Future<void> _findNearby(BuildContext context) async {
    final have = app.myPucks.map((p) => p.puck).toSet();
    final seen = await pickPuckNearby(context, exclude: have, title: 'Pucks nearby (tap one to set it up)');
    if (seen == null || !context.mounted) return;
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PuckSetupScreen(nearby: seen)));
  }

  /// Forget it here and, if it had one, revoke its key on the server so it can't upload as you any more.
  Future<void> _forget(BuildContext context, MyPuck p) async {
    final keyed = p.keyId > 0 && app.signedIn;
    if (!await confirm(
      context,
      'Forget puck ${p.puck}?',
      keyed
          ? 'Its key is revoked on the server, so its sails can\'t go up as you any more (sold it, or lost it?). The sails already here stay. The puck itself keeps the old key until someone holds its button 6 s and sets it up again.'
          : p.keyId > 0
              ? 'It\'s taken off this list. Its key can\'t be revoked while you\'re signed out — sign in and forget it again to do that.'
              : 'It\'s taken off this list. The puck itself keeps its settings until you set it up again.',
      ok: 'Forget',
      danger: true,
    )) {
      return;
    }
    if (keyed) {
      try {
        await app.auth.revokePuckKey(p.keyId);
      } on AuthException catch (e) {
        if (e.status != 404) {
          if (context.mounted) toast(context, 'Couldn\'t reach the server to revoke its key: ${e.message}', error: true);
          return;
        }
      } catch (e) {
        if (context.mounted) toast(context, 'Couldn\'t reach the server to revoke its key: ${friendly(e)}', error: true);
        return;
      }
    }
    await app.removeMyPuck(p.puck);
    if (context.mounted) toast(context, 'Puck ${p.puck} forgotten');
  }
}
