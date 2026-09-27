import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../sync/server_sync.dart';
import '../widgets/common.dart';
import 'web_page.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final TextEditingController _url = TextEditingController(text: app.serverUrl);
  List<DayCompare>? _days;
  String? _error;
  bool _checking = false;
  final Map<String, String> _busy = {}; // day -> progress text
  final Map<String, String> _done = {}; // day -> result text

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  ServerSync? get _sync => app.serverUrl.isEmpty || app.demoMode ? null : ServerSync(app.serverUrl, app.store, token: app.token);

  Future<void> _lostSession(Object e) async {
    if (e is SyncException && e.signedOut && app.signedIn) {
      await app.signOut(tellServer: false);
      if (mounted) toast(context, 'Your sign-in has expired. Log in again from Setup → You.', error: true);
    }
  }

  Future<void> _check() async {
    if (!app.signedIn) {
      app.serverUrl = _url.text;
      _url.text = app.serverUrl;
    }
    final s = _sync;
    if (s == null) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final d = await s.compare();
      if (mounted) setState(() => _days = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      await _lostSession(e);
    }
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _syncDay(DayCompare c, {Map<String, String> resolve = const {}}) async {
    final s = _sync;
    if (s == null) return;
    setState(() {
      _busy[c.day] = 'Starting…';
      _done.remove(c.day);
    });
    try {
      final r = await s.syncDay(c, resolve: resolve, progress: (msg) {
        if (mounted) setState(() => _busy[c.day] = msg);
      });
      final parts = <String>[
        if (r.up > 0) '${r.up} track${r.up == 1 ? '' : 's'} up',
        if (r.down > 0) '${r.down} down',
        ...r.changed,
      ];
      if (mounted) setState(() => _done[c.day] = parts.isEmpty ? 'Already in sync' : parts.join(' · '));
      if (r.conflicts.isNotEmpty && mounted) {
        setState(() => _busy.remove(c.day));
        await _resolve(c, r.conflicts);
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _done[c.day] = 'Failed: $e');
      await _lostSession(e);
    }
    if (mounted) setState(() => _busy.remove(c.day));
    await _refreshQuietly();
  }

  Future<void> _resolve(DayCompare c, List<String> conflicts) async {
    final what = conflicts.map((w) => w == 'races' ? 'race times' : 'course (marks, lines, gun, corrections)').join(' and ');
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${c.day}: which to keep?'),
        content: Text('The $what for this day are different on the phone and on the server. '
            'Keep the phone\'s (and update the server), or keep the server\'s (and update the phone)?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Leave both')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'server'), child: const Text('Server\'s')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'phone'), child: const Text('Phone\'s')),
        ],
      ),
    );
    if (!mounted) return;
    if (pick == null) {
      setState(() => _done[c.day] = '${_done[c.day] ?? ''} · $what left different');
      await _refreshQuietly();
      return;
    }
    final first = _done[c.day];
    // tracks were already copied on the first pass — this pass only settles the course
    final courseOnly = DayCompare(c.day, const [], const [], [...c.both, ...c.phoneOnly, ...c.serverOnly]);
    await _syncDay(courseOnly, resolve: {for (final w in conflicts) w: pick});
    if (mounted && first != null && first != 'Already in sync') setState(() => _done[c.day] = '$first · ${_done[c.day]}');
  }

  Future<void> _refreshQuietly() async {
    final s = _sync;
    if (s == null) return;
    try {
      final d = await s.compare();
      if (mounted) setState(() => _days = d);
    } catch (_) {}
  }

  Future<void> _syncAll() async {
    for (final c in List.of(_days ?? const <DayCompare>[])) {
      await _syncDay(c);
    }
    if (mounted) toast(context, 'Sync finished');
  }

  Future<void> _invite() async {
    final url = app.serverUrl;
    await Share.share(
      'Join me on WakeBack — record your sailing and replay our races together.\n\n'
      'Get the app, create an account, then add me as a friend (Setup → Friends): ${app.account?.email ?? ''}\n'
      'Server: $url',
      subject: 'WakeBack',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: app, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final t = Theme.of(context);
    final hasServer = app.serverUrl.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(app.signedIn ? 'Sync' : 'Sync with a server')),
      body: app.demoMode
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Hint('Sync is off in demo mode, so pretend data never reaches your account. Leave the demo in Setup to sync your real sailing.'),
              ),
            )
          : RefreshIndicator(
        onRefresh: _check,
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 24), children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (app.signedIn)
                  Row(children: [
                    Icon(Icons.verified_user_outlined, color: t.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Signed in as ${app.account!.name} · ${Uri.parse(app.serverUrl).host}', style: t.textTheme.bodyMedium)),
                  ])
                else ...[
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'https://wakeback.bridgesolutions.uk',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    onSubmitted: (_) => _check(),
                  ),
                  const SizedBox(height: 6),
                  const Hint('Not signed in: sync works with a dock Pi or a server without accounts. For your WakeBack account, sign in from Setup → You.'),
                ],
                const SizedBox(height: 8),
                const Hint('Sync copies each session\'s tracks, names, races and course both ways, and brings down your friends\' sails.'),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    onPressed: _checking ? null : _check,
                    icon: _checking
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.compare_arrows),
                    label: const Text('Check'),
                  ),
                  if (hasServer && (_days?.isNotEmpty ?? false))
                    FilledButton.tonalIcon(onPressed: _busy.isNotEmpty ? null : _syncAll, icon: const Icon(Icons.sync), label: const Text('Sync all')),
                  if (hasServer)
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerViewerPage(url: app.serverUrl))),
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('Open server'),
                    ),
                  if (hasServer) OutlinedButton.icon(onPressed: _invite, icon: const Icon(Icons.person_add_alt), label: const Text('Invite a mate')),
                ]),
              ]),
            ),
          ),
          if (_error != null)
            Card(
              color: Colors.red.shade900.withValues(alpha: 0.5),
              child: ListTile(leading: const Icon(Icons.error_outline), title: Text(_error!)),
            ),
          if (_days != null) ...[
            const SectionLabel('Sailing days'),
            if (_days!.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No sessions on the phone or the server yet'))),
            for (final c in _days!) _dayTile(t, c),
          ] else if (!_checking && _error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Hint('Put in your server address and tap Check to compare what\'s on the phone with what\'s on the server.'),
            ),
        ]),
      ),
    );
  }

  Widget _dayTile(ThemeData t, DayCompare c) {
    final bits = <String>[
      if (c.phoneOnly.isNotEmpty) '${c.phoneOnly.length} only on phone',
      if (c.serverOnly.isNotEmpty) '${c.serverOnly.length} only on server',
      if (c.both.isNotEmpty) '${c.both.length} on both',
    ];
    final busy = _busy[c.day];
    final done = _done[c.day];
    return Card(
      child: ListTile(
        leading: Icon(
          c.tracksInSync ? Icons.cloud_done_outlined : (c.onServer ? Icons.cloud_sync_outlined : Icons.cloud_upload_outlined),
          color: c.tracksInSync ? Colors.greenAccent : t.colorScheme.primary,
        ),
        title: Text(c.day),
        subtitle: Text([bits.join(' · '), if (busy != null) busy, if (done != null) done].join('\n')),
        isThreeLine: busy != null || done != null,
        trailing: busy != null
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(onPressed: () => _syncDay(c), child: const Text('Sync')),
      ),
    );
  }
}
