// "Update available" card (Sessions tab) and the About row in Setup: version, check, install.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../updates.dart';
import '../widgets/common.dart';

class UpdateCard extends StatefulWidget {
  final AppUpdate update;
  const UpdateCard(this.update, {super.key});
  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  double? _progress; // null = not downloading
  bool _expanded = false;

  Future<void> _install() async {
    setState(() => _progress = 0);
    try {
      await Updates.instance.install(widget.update, progress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) toast(context, 'Android\'s installer should be open. If it asks, allow WakeBack to install updates.');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t install: $e. You can still get it from the releases page.', error: true);
    }
    if (mounted) setState(() => _progress = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final u = widget.update;
    final notes = u.notes.trim();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.system_update, color: t.colorScheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Update available: WakeBack ${u.version.isEmpty ? 'build ${u.build}' : '${u.version} (build ${u.build})'}',
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: t.colorScheme.onTertiaryContainer)),
            ),
            IconButton(icon: const Icon(Icons.close, size: 20), tooltip: 'Not now', onPressed: _progress == null ? app.dismissUpdate : null),
          ]),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(notes, maxLines: _expanded ? null : 3, overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onTertiaryContainer)),
            ),
          ],
          const SizedBox(height: 8),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: _progress! > 0 ? _progress : null),
                const SizedBox(height: 4),
                Text('Downloading… ${(_progress! * 100).round()}%', style: t.textTheme.labelSmall),
              ]),
            )
          else
            FilledButton.icon(onPressed: _install, icon: const Icon(Icons.download), label: const Text('Download and install')),
        ]),
      ),
    );
  }
}

/// Setup → About: the version, a check button, and the update card when there is one.
class AboutCard extends StatefulWidget {
  const AboutCard({super.key});
  @override
  State<AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends State<AboutCard> {
  String _version = '…';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    Updates.instance.installed().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      final u = await app.checkForUpdate(force: true);
      if (mounted) toast(context, u == null ? 'You\'re on the latest build' : 'Build ${u.build} is available — see the card above');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t check: $e', error: true);
    }
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final u = app.pendingUpdate;
    return Column(children: [
      if (u != null) UpdateCard(u),
      Card(
        child: ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('WakeBack'),
          subtitle: Text('Version $_version · updates come from the releases page on GitHub'),
          trailing: _checking
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(onPressed: _check, child: const Text('Check')),
        ),
      ),
    ]);
  }
}
