// "Your pucks" on the You tab: the pucks set up from this phone, set up another, set one up again, forget one.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../auth/auth_api.dart';
import '../widgets/common.dart';
import 'puck_setup_screen.dart';
import 'web_page.dart';

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
              ? 'Set a puck up from here: it then records every sail by itself and uploads to this phone.'
              : 'Upload to this phone over hotspot "${app.hotspotName}" whenever WakeBack is open.'),
          isThreeLine: pucks.isEmpty,
        ),
        for (final p in pucks)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 16, backgroundColor: t.colorScheme.primary, child: Text('${p.puck}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700))),
            title: Text('Puck ${p.puck}'),
            subtitle: Text([
              if (p.fw.isNotEmpty) 'firmware ${p.fw}',
              p.keyId > 0 ? 'uploads as you' : 'no account key',
              if (p.setUpMs > 0) 'set up ${_when(p.setUpMs)}',
            ].join(' · ')),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => v == 'again' ? _setUp(context, p.puck) : _forget(context, p),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'again', child: Text('Set up again')),
                PopupMenuItem(value: 'forget', child: Text('Forget this puck')),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.icon(onPressed: () => _setUp(context, null), icon: const Icon(Icons.add, size: 18), label: Text(pucks.isEmpty ? 'Set up a puck' : 'Set up another')),
            if (pucks.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerViewerPage(url: '${app.dock.localUrl}/dock', title: 'Pucks'))),
                icon: const Icon(Icons.monitor_heart_outlined, size: 18),
                label: const Text('See them check in'),
              ),
          ]),
        ),
      ]),
    );
  }

  static String _when(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}';
  }

  Future<void> _setUp(BuildContext context, int? puck) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PuckSetupScreen(puck: puck)));
  }

  /// Forget it here and, if it had one, revoke its key on the server so it can't upload as you any more.
  Future<void> _forget(BuildContext context, MyPuck p) async {
    final keyed = p.keyId > 0 && app.signedIn;
    if (!await confirm(
      context,
      'Forget puck ${p.puck}?',
      keyed
          ? 'Its key is revoked on the server, so it can\'t upload as you any more (sold it, or lost it?). Its sails already uploaded stay. Setting it up again gives it a new key.'
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
      }
    }
    await app.removeMyPuck(p.puck);
    if (context.mounted) toast(context, 'Puck ${p.puck} forgotten');
  }
}
