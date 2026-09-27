// Setup → Friends: who you share with, requests in and out, add by email.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../auth/auth_api.dart';
import '../widgets/common.dart';

class FriendsSection extends StatefulWidget {
  const FriendsSection({super.key});
  @override
  State<FriendsSection> createState() => _FriendsSectionState();
}

class _FriendsSectionState extends State<FriendsSection> {
  FriendLists? _lists;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!app.signedIn) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await app.auth.friends();
      if (mounted) setState(() => _lists = l);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final c = TextEditingController();
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a friend'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Their email', helperText: 'The one they used for their WakeBack account'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Send request')),
        ],
      ),
    );
    if (email == null || email.isEmpty) return;
    try {
      final st = await app.auth.requestFriend(email);
      if (mounted) toast(context, st == 'accepted' ? 'You\'re now friends: they\'d already asked you' : 'Request sent. They accept it in their app.');
      await _load();
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
  }

  Future<void> _act(Future<void> Function() f, String done) async {
    try {
      await f();
      if (mounted) toast(context, done);
      await _load();
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final l = _lists;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Friends', style: t.textTheme.titleMedium),
            const Spacer(),
            if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) else IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
            FilledButton.tonalIcon(onPressed: _add, icon: const Icon(Icons.person_add_alt), label: const Text('Add')),
          ]),
          const Hint('Friends see each other\'s sails (unless a sail is set private), so you can replay who you raced against.'),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
          if (l != null) ...[
            if (l.incoming.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Want to be friends with you', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
              for (final f in l.incoming)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(f.name),
                  trailing: Wrap(spacing: 4, children: [
                    TextButton(onPressed: () => _act(() => app.auth.declineFriend(f.id), 'Declined'), child: const Text('Decline')),
                    FilledButton(onPressed: () => _act(() => app.auth.acceptFriend(f.id), 'You\'re now friends with ${f.name}'), child: const Text('Accept')),
                  ]),
                ),
            ],
            const SizedBox(height: 6),
            if (l.friends.isEmpty && l.outgoing.isEmpty && l.incoming.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('No friends yet. Add your sailing mates by the email they signed up with.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
            for (final f in l.friends)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(backgroundColor: t.colorScheme.primary, child: Text(f.name.isEmpty ? '?' : f.name[0].toUpperCase(), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700))),
                title: Text(f.name),
                trailing: IconButton(
                  tooltip: 'Remove friend',
                  icon: const Icon(Icons.person_remove_outlined),
                  onPressed: () async {
                    if (await confirm(context, 'Remove ${f.name}?', 'You\'ll stop seeing each other\'s sails.', ok: 'Remove', danger: true)) {
                      await _act(() => app.auth.unfriend(f.id), 'Removed');
                    }
                  },
                ),
              ),
            for (final f in l.outgoing)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.hourglass_empty)),
                title: Text(f.name),
                subtitle: const Text('Waiting for them to accept'),
                trailing: TextButton(onPressed: () => _act(() => app.auth.unfriend(f.id), 'Request cancelled'), child: const Text('Cancel')),
              ),
          ],
        ]),
      ),
    );
  }
}
