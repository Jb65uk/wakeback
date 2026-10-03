// The Sync page (opened from the cloud on the Sails tab). Sails sync on their own; this is where you see
// each day, sync names, races and course, and settle a course that differs.
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../sync/server_sync.dart';
import '../widgets/common.dart';
import 'sessions_screen.dart' show niceDate;
import 'web_page.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final TextEditingController _url = TextEditingController(text: app.serverUrl);
  List<DayCompare>? _days;
  String? _error, _errorDetail;
  bool _checking = false;
  final Map<String, String> _busy = {}; // day -> progress text
  final Map<String, String> _done = {}; // day -> result text

  @override
  void initState() {
    super.initState();
    // signed in: show where things stand straight away, no button to find
    if (app.signedIn && !app.demoMode) WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  ServerSync? get _sync => app.serverUrl.isEmpty || app.demoMode ? null : ServerSync(app.serverUrl, app.store, token: app.token);

  /// "Sat 3 Oct 2026 · Southport SC" rather than the folder name.
  String _label(DayCompare c) {
    if (c.date.isEmpty) return c.day;
    return c.venueName.isEmpty ? niceDate(c.date) : '${niceDate(c.date)} · ${c.venueName}';
  }

  Future<void> _lostSession(Object e) async {
    if (e is SyncException && e.signedOut && app.signedIn) {
      await app.signOut(tellServer: false);
      if (mounted) toast(context, 'Your sign-in has expired. Log in again from the You tab.', error: true);
    }
  }

  void _showError(Object e) {
    _error = e is SyncException ? e.message : 'Something went wrong while syncing.';
    _errorDetail = e is SyncException ? e.detail : '$e';
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
      _error = _errorDetail = null;
    });
    try {
      final d = await s.compare();
      if (mounted) setState(() => _days = d);
    } catch (e) {
      if (mounted) setState(() => _showError(e));
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
        if (r.up > 0) '${r.up} track${r.up == 1 ? '' : 's'} sent',
        if (r.down > 0) '${r.down} fetched',
        ...r.changed,
      ];
      if (mounted) setState(() => _done[c.day] = parts.isEmpty ? 'Up to date' : parts.join(' · '));
      if (r.conflicts.isNotEmpty && mounted) {
        setState(() => _busy.remove(c.day));
        await _resolve(c, r.conflicts);
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _done[c.day] = 'Didn\'t finish';
          _showError(e);
        });
      }
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
        title: Text('${_label(c)}: which to keep?'),
        content: Text('The $what are different on this device and on the server. Which should both use?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Leave both')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'server'), child: const Text('Server\'s')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'phone'), child: const Text('This device\'s')),
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
    final courseOnly = DayCompare(c.day, const [], const [], [...c.both, ...c.phoneOnly, ...c.serverOnly], date: c.date, venueName: c.venueName);
    await _syncDay(courseOnly, resolve: {for (final w in conflicts) w: pick});
    if (mounted && first != null && first != 'Up to date') setState(() => _done[c.day] = '$first · ${_done[c.day]}');
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
    setState(() => _error = _errorDetail = null);
    for (final c in List.of(_days ?? const <DayCompare>[])) {
      await _syncDay(c);
      if (_error != null) break; // no connection: don't fail the same way for every day
    }
    if (mounted && _error == null) toast(context, 'Everything is up to date');
  }

  Future<void> _invite() async {
    final url = app.serverUrl;
    await Share.share(
      'Join me on WakeBack — record your sailing and replay our races together.\n\n'
      'Get the app, create an account, then add me as a friend (You → Friends): ${app.account?.email ?? ''}\n'
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
    final days = _days;
    final allDone = days != null && days.every((c) => c.tracksInSync);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          if (hasServer && !app.demoMode)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'open') Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ServerViewerPage(url: app.serverUrl)));
                if (v == 'invite') _invite();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'invite', child: ListTile(leading: Icon(Icons.person_add_alt), title: Text('Invite a mate'), contentPadding: EdgeInsets.zero)),
                PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_browser), title: Text('Open the server in a browser'), contentPadding: EdgeInsets.zero)),
              ],
            ),
        ],
      ),
      body: app.demoMode
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Hint('Sync is off in demo mode. Leave the demo (You tab) to sync your real sailing.'),
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
                          Icon(_error != null ? Icons.cloud_off : (allDone ? Icons.cloud_done_outlined : Icons.cloud_sync_outlined),
                              color: _error != null ? Colors.orangeAccent : (allDone ? Colors.greenAccent : t.colorScheme.primary)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _checking && days == null
                                  ? 'Checking…'
                                  : _error != null
                                      ? 'Not synced'
                                      : allDone
                                          ? 'Everything is up to date'
                                          : days == null
                                              ? 'Signed in as ${app.account!.name}'
                                              : 'Some days have tracks to sync',
                              style: t.textTheme.titleMedium,
                            ),
                          ),
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
                        const Hint('Not signed in: this syncs with a dock Pi or a server without accounts. For your account, sign in from the You tab.'),
                      ],
                      const SizedBox(height: 6),
                      Hint(app.signedIn ? 'Your sails sync on their own. Signed in as ${app.account!.name}.' : 'Copies tracks, names, races and course both ways.'),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.icon(
                          onPressed: _checking ? null : _check,
                          icon: _checking
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.refresh),
                          label: Text(app.signedIn ? 'Check again' : 'Check'),
                        ),
                        if (hasServer && (days?.isNotEmpty ?? false))
                          FilledButton.tonalIcon(onPressed: _busy.isNotEmpty ? null : _syncAll, icon: const Icon(Icons.sync), label: const Text('Sync all')),
                      ]),
                    ]),
                  ),
                ),
                if (_error != null)
                  Card(
                    color: Colors.orange.shade900.withValues(alpha: 0.45),
                    clipBehavior: Clip.antiAlias,
                    child: _errorDetail == null
                        ? ListTile(leading: const Icon(Icons.info_outline), title: Text(_error!))
                        : ExpansionTile(
                            leading: const Icon(Icons.info_outline),
                            title: Text(_error!, style: t.textTheme.bodyLarge),
                            subtitle: const Text('Details'),
                            shape: const Border(),
                            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            expandedAlignment: Alignment.centerLeft,
                            children: [SelectableText(_errorDetail!, style: t.textTheme.bodySmall)],
                          ),
                  ),
                if (days != null) ...[
                  const SectionLabel('Sailing days'),
                  if (days.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No sails here or on the server yet'))),
                  for (final c in days) _dayTile(t, c),
                ],
              ]),
            ),
    );
  }

  Widget _dayTile(ThemeData t, DayCompare c) {
    final bits = <String>[
      if (c.tracksInSync) 'Up to date',
      if (c.serverOnly.isNotEmpty) '${c.serverOnly.length} to fetch',
      if (c.phoneOnly.isNotEmpty) '${c.phoneOnly.length} only on this device',
    ];
    final busy = _busy[c.day];
    final done = _done[c.day];
    return Card(
      child: ListTile(
        leading: Icon(
          c.tracksInSync ? Icons.cloud_done_outlined : (c.onServer ? Icons.cloud_sync_outlined : Icons.cloud_upload_outlined),
          color: c.tracksInSync ? Colors.greenAccent : t.colorScheme.primary,
        ),
        title: Text(_label(c)),
        subtitle: Text(busy ?? done ?? bits.join(' · ')),
        trailing: busy != null
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(onPressed: () => _syncDay(c), child: const Text('Sync')),
      ),
    );
  }
}
