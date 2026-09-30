// Boats: which boat you sailed in a session. Most people have one (it goes on every track by itself);
// some have a couple, so a session's boat can be changed from a short list you build up as you go.
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

/// Pick a boat for a session: your boats, "add a boat", or none. Returns null when dismissed,
/// '' for "no boat", else the boat's name (remembered in your list if it's new).
Future<String?> pickBoat(BuildContext context, {String current = ''}) async {
  final r = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _BoatSheet(current: current),
  );
  if (r != null && r.isNotEmpty) await app.rememberBoat(r);
  return r;
}

class _BoatSheet extends StatefulWidget {
  final String current;
  const _BoatSheet({required this.current});
  @override
  State<_BoatSheet> createState() => _BoatSheetState();
}

class _BoatSheetState extends State<_BoatSheet> {
  final _new = TextEditingController();

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  void _add() {
    final v = _new.text.trim();
    if (v.isEmpty) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final boats = app.boats;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Which boat?', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          ),
          for (final b in boats)
            ListTile(
              leading: Icon(b == widget.current ? Icons.radio_button_checked : Icons.radio_button_off, color: b == widget.current ? t.colorScheme.primary : null),
              title: Text(b),
              subtitle: b == app.defaultBoat ? const Text('Your usual boat') : null,
              onTap: () => Navigator.pop(context, b),
            ),
          if (widget.current.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('No boat on this session'),
              onTap: () => Navigator.pop(context, ''),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _new,
                  autofocus: boats.isEmpty,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: kBoatHint, border: OutlineInputBorder(), isDense: true),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _add, child: const Text('Add')),
            ]),
          ),
        ]),
      ),
    );
  }
}

const kBoatHint = 'Add a boat, e.g. Solo 5843';

/// Setup → Your boats: the list, your usual boat first.
class BoatsCard extends StatefulWidget {
  const BoatsCard({super.key});
  @override
  State<BoatsCard> createState() => _BoatsCardState();
}

class _BoatsCardState extends State<BoatsCard> {
  final _new = TextEditingController();

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final v = _new.text.trim();
    if (v.isEmpty) return;
    await app.setBoats([...app.boats, v]);
    _new.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final boats = app.boats;
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          leading: const Icon(Icons.sailing_outlined),
          title: const Text('Your boats'),
          subtitle: Text(boats.isEmpty
              ? 'Add the boat you sail and it goes on your tracks by itself.'
              : boats.length == 1
                  ? '${boats.first} goes on every track you record.'
                  : '${boats.first} goes on new tracks; change a session\'s boat from its card in Sessions.'),
        ),
        for (var i = 0; i < boats.length; i++)
          ListTile(
            dense: true,
            leading: Icon(i == 0 ? Icons.star : Icons.star_border, size: 20, color: i == 0 ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
            title: Text(boats[i]),
            subtitle: i == 0 ? const Text('Usual boat') : null,
            onTap: i == 0
                ? null
                : () async {
                    // tapping makes it the usual boat
                    final l = [...boats]..removeAt(i);
                    await app.setBoats([boats[i], ...l]);
                    setState(() {});
                  },
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () async {
                if (await confirm(context, 'Remove ${boats[i]}?', 'Sessions already tagged with it keep the name.', ok: 'Remove')) {
                  await app.setBoats([...boats]..removeAt(i));
                  setState(() {});
                }
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _new,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: kBoatHint, border: OutlineInputBorder(), isDense: true),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: _add, child: const Text('Add')),
          ]),
        ),
      ]),
    );
  }
}
