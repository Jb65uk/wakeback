// The Sessions tab: every sailing session on this phone (tap one to replay it, choose which are shared
// with friends), your totals, and the friends' league table.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../sync/server_sync.dart';
import '../widgets/common.dart';

class SessionsScreen extends StatefulWidget {
  /// Open a session in the Replay tab.
  final void Function(String id) onOpen;
  const SessionsScreen({super.key, required this.onOpen});
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      Material(
        color: t.colorScheme.surface,
        child: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Sessions'), Tab(text: 'Stats'), Tab(text: 'League')],
        ),
      ),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _SessionList(onOpen: widget.onOpen),
          _StatsTab(onOpen: widget.onOpen),
          const _LeagueTab(),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- helpers

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// '2026-09-20' -> 'Sun 20 Sep 2026'
String niceDate(String ymd) {
  try {
    final d = DateTime.parse(ymd);
    return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${d.year}';
  } catch (_) {
    return ymd;
  }
}

/// '2026-09' -> 'Sep 26'
String niceMonth(String ym) {
  try {
    final p = ym.split('-');
    return '${_months[int.parse(p[1]) - 1]} ${p[0].substring(2)}';
  } catch (_) {
    return ym;
  }
}

String niceHours(num h) {
  if (h < 1) return '${(h * 60).round()} min';
  return h >= 10 ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
}

String nm(num v, [int dp = 1]) => v.toStringAsFixed(v >= 100 ? 0 : dp);

/// Sync to the server, when there's one to talk to.
ServerSync? serverOrNull() => app.signedIn && !app.demoMode && app.serverUrl.isNotEmpty ? ServerSync(app.serverUrl, app.store, token: app.token) : null;

class _PeriodPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _PeriodPicker(this.value, this.onChanged);
  @override
  Widget build(BuildContext context) => SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'month', label: Text('This month')),
          ButtonSegment(value: 'year', label: Text('This year')),
          ButtonSegment(value: 'all', label: Text('All time')),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title, body;
  const _Empty(this.icon, this.title, this.body);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- Sessions

class _SessionList extends StatefulWidget {
  final void Function(String id) onOpen;
  const _SessionList({required this.onOpen});
  @override
  State<_SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<_SessionList> {
  List<Map<String, dynamic>>? _list;
  String? _err;
  Timer? _refresh;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
    app.addListener(_load); // demo on/off, sign in/out: different data
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => _load()); // a puck may have just landed
  }

  @override
  void dispose() {
    _refresh?.cancel();
    app.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await app.store.sessions();
      if (mounted) {
        setState(() {
          _list = l;
          _err = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  /// My tracks in this session, and whether any of them is shared with friends.
  (List<String>, bool) _mine(Map<String, dynamic> s) {
    final mine = ((s['mine'] as List?) ?? const []).cast<String>();
    final sharing = (s['sharing'] as Map?) ?? const {};
    return (mine, mine.any((f) => (sharing[f] ?? 'friends') == 'friends'));
  }

  Future<void> _setShared(Map<String, dynamic> s, bool on) async {
    final id = s['id'] as String;
    final (mine, _) = _mine(s);
    final vis = on ? 'friends' : 'private';
    setState(() => _busy.add(id));
    try {
      for (final f in mine) {
        await app.store.trackSettings(id, f, {'visibility': vis});
      }
      final sync = serverOrNull();
      if (sync != null) {
        var failed = 0;
        for (final f in mine) {
          try {
            await sync.setSharing(id, f, vis);
          } on SyncException catch (e) {
            // not on the server yet (sync will carry the setting up with the track) — anything else, say so
            if (!e.message.contains('404') && !e.message.toLowerCase().contains('not found')) failed++;
          }
        }
        if (failed > 0 && mounted) toast(context, 'Changed here; the server didn\'t take it for $failed track${failed > 1 ? 's' : ''} — try again after a Sync', error: true);
      }
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
    _busy.remove(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final list = _list;
    if (list == null) return _err == null ? const Center(child: CircularProgressIndicator()) : _Empty(Icons.error_outline, 'Couldn\'t read your sessions', _err!);
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [
          SizedBox(height: 80),
          _Empty(Icons.sailing_outlined, 'No sessions yet',
              'When a puck joins your hotspot its track lands here. You can also add a GPX from a phone or watch in Replay, or pull your sessions down from the server in Sync.'),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: list.length + 1,
        itemBuilder: (context, i) {
          if (i == list.length) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              child: Hint(app.signedIn
                  ? 'Friends: your friends can see this session\'s tracks (and you appear in their league). Private: only you. The switch covers your own tracks; a mate\'s track you synced down stays theirs.'
                  : 'Sign in (Setup → You) to share sessions with friends and see the league.'),
            );
          }
          final s = list[i];
          final id = s['id'] as String;
          final files = (s['files'] as List).length;
          final races = (s['races'] as num?)?.toInt() ?? 0;
          final stats = (s['stats'] as Map?) ?? const {};
          final (mine, shared) = _mine(s);
          double dist = 0, top = 0;
          for (final f in mine.isNotEmpty ? mine : (s['files'] as List).cast<String>()) {
            final st = stats[f];
            if (st is Map) {
              dist += (st['dist_nm'] as num?)?.toDouble() ?? 0;
              final mk = (st['max_kn'] as num?)?.toDouble() ?? 0;
              if (mk > top) top = mk;
            }
          }
          final others = files - mine.length;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => widget.onOpen(id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(niceDate('${s['date']}'), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('${s['venue_name']}${s['venue_new'] == true ? '  ·  new venue, name it in Replay' : ''}',
                          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 14, runSpacing: 4, children: [
                        _Fact(Icons.route_outlined, dist > 0 ? '${nm(dist)} nm' : '—'),
                        _Fact(Icons.speed, top > 0 ? '${top.toStringAsFixed(1)} kn' : '—'),
                        _Fact(Icons.directions_boat_outlined, '$files track${files == 1 ? '' : 's'}${others > 0 && mine.isNotEmpty ? ' ($others mates)' : ''}'),
                        if (races > 0) _Fact(Icons.flag_outlined, '$races race${races == 1 ? '' : 's'}'),
                      ]),
                    ]),
                  ),
                  if (mine.isNotEmpty)
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Switch(
                        value: shared,
                        onChanged: _busy.contains(id) ? null : (v) => _setShared(s, v),
                        thumbIcon: WidgetStateProperty.resolveWith((st) => Icon(st.contains(WidgetState.selected) ? Icons.group : Icons.lock_outline)),
                      ),
                      Text(shared ? 'Friends' : 'Private', style: t.textTheme.labelSmall?.copyWith(color: shared ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant)),
                    ])
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.chevron_right, color: t.colorScheme.onSurfaceVariant),
                    ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Fact(this.icon, this.text);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: t.colorScheme.onSurfaceVariant),
      const SizedBox(width: 4),
      Text(text, style: t.textTheme.bodySmall),
    ]);
  }
}

// ---------------------------------------------------------------- Stats

class _StatsTab extends StatefulWidget {
  final void Function(String id) onOpen;
  const _StatsTab({required this.onOpen});
  @override
  State<_StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<_StatsTab> {
  String _period = 'all';
  Map<String, dynamic>? _st;
  String? _err, _source;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
    app.addListener(_load);
  }

  @override
  void dispose() {
    app.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final n = ++_req;
    final period = _period;
    Map<String, dynamic>? st;
    String? src, err;
    final sync = serverOrNull();
    if (sync != null) {
      try {
        st = await sync.myStats(period);
        src = 'everything you\'ve synced to the server';
      } on SyncException catch (e) {
        err = e.message;
      }
    }
    if (st == null) {
      try {
        st = await app.store.myStats(period);
        src = sync == null ? null : 'this phone only (${err ?? 'server not reached'})';
        err = null;
      } catch (e) {
        err = '$e';
      }
    }
    if (mounted && n == _req && period == _period) {
      setState(() {
        _st = st;
        _err = err;
        _source = src;
      });
    }
  }

  void _setPeriod(String p) {
    setState(() {
      _period = p;
      _st = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = _st;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
        Center(child: _PeriodPicker(_period, _setPeriod)),
        const SizedBox(height: 12),
        if (st == null && _err != null) _Empty(Icons.error_outline, 'Couldn\'t work out your stats', _err!),
        if (st == null && _err == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (st != null && (st['tracks'] as num? ?? 0) == 0)
          _Empty(Icons.insights_outlined, _period == 'all' ? 'Nothing to count yet' : 'Nothing ${_period == 'month' ? 'this month' : 'this year'}',
              _period == 'all' ? 'Your own tracks add up here: miles, hours, top speeds.' : 'Time to go sailing.'),
        if (st != null && (st['tracks'] as num? ?? 0) > 0) ..._body(t, st),
        if (_source != null) ...[
          const SizedBox(height: 16),
          Center(child: Hint('Counting $_source.')),
        ],
      ]),
    );
  }

  List<Widget> _body(ThemeData t, Map<String, dynamic> st) {
    final dist = (st['dist_nm'] as num).toDouble(), h = (st['moving_h'] as num).toDouble();
    final sessions = (st['sessions'] as num).toInt();
    final maxT = (st['max_track'] as Map?) ?? const {}, bestT = (st['best_avg_track'] as Map?) ?? const {}, longT = (st['longest_track'] as Map?) ?? const {};
    String where(Map m) => m.isEmpty ? '' : '${niceDate('${m['date']}')} · ${m['venue_name']}';
    final months = ((st['by_month'] as List?) ?? const []).whereType<Map>().toList();
    return [
      Row(children: [
        Expanded(child: _Big(nm(dist), 'nautical miles', Icons.route_outlined, t)),
        const SizedBox(width: 8),
        Expanded(child: _Big(niceHours(h), 'on the water', Icons.timer_outlined, t)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _Big('$sessions', sessions == 1 ? 'session' : 'sessions', Icons.calendar_month_outlined, t)),
        const SizedBox(width: 8),
        Expanded(child: _Big((st['avg_kn'] as num).toStringAsFixed(1), 'kn average', Icons.trending_flat, t)),
      ]),
      const SizedBox(height: 12),
      _Record(Icons.bolt, 'Top speed', '${(st['max_kn'] as num).toStringAsFixed(1)} kn', where(maxT), () => _open(maxT)),
      _Record(Icons.speed, 'Fastest average', '${(st['best_avg_kn'] as num).toStringAsFixed(1)} kn', where(bestT), () => _open(bestT)),
      _Record(Icons.straighten, 'Longest sail', '${nm((st['longest_nm'] as num?) ?? 0)} nm', where(longT), () => _open(longT)),
      if (st['favourite_venue'] != null)
        _Record(Icons.place_outlined, 'Favourite venue', '${st['favourite_venue']}',
            '${st['venues']} venue${st['venues'] == 1 ? '' : 's'} · since ${niceDate('${st['first_date']}')}', null),
      const SizedBox(height: 12),
      _FunFact(dist, h, t),
      if (months.length > 1) ...[
        const SectionLabel('Miles by month'),
        _MonthBars(months, t),
      ],
    ];
  }

  void _open(Map m) {
    final id = m['session'];
    if (id is String) widget.onOpen(id);
  }
}

class _Big extends StatelessWidget {
  final String value, label;
  final IconData icon;
  final ThemeData t;
  const _Big(this.value, this.label, this.icon, this.t);
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: t.colorScheme.primary),
            const SizedBox(height: 6),
            Text(value, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.0)),
            const SizedBox(height: 2),
            Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
      );
}

class _Record extends StatelessWidget {
  final IconData icon;
  final String title, value, sub;
  final VoidCallback? onTap;
  const _Record(this.icon, this.title, this.value, this.sub, this.onTap);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, color: t.colorScheme.primary),
        title: Text(title),
        subtitle: sub.isEmpty ? null : Text(sub),
        trailing: Text(value, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        onTap: onTap,
      ),
    );
  }
}

class _FunFact extends StatelessWidget {
  final double nmiles, hrs;
  final ThemeData t;
  const _FunFact(this.nmiles, this.hrs, this.t);

  String get text {
    // distances, in nautical miles, that a dinghy sailor can picture
    const legs = [
      (1.0, 'a decent-sized lake'),
      (21.0, 'Dover to Calais'),
      (50.0, 'round the Isle of Wight'),
      (95.0, 'Liverpool to Dublin'),
      (605.0, 'the Fastnet course'),
      (1800.0, 'right round Britain'),
      (2900.0, 'across the Atlantic'),
    ];
    if (nmiles < 0.5) return 'Every mile starts somewhere. Go sail!';
    var pick = legs.first;
    for (final l in legs) {
      if (nmiles >= l.$1 * 0.9) pick = l;
    }
    final times = nmiles / pick.$1;
    final howMany = times >= 2 ? '${times.toStringAsFixed(times >= 10 ? 0 : 1)} times' : times >= 0.9 ? 'about once' : '${(times * 100).round()}% of the way';
    final afloat = hrs >= 24 ? ' — and ${(hrs / 24).toStringAsFixed(1)} whole days afloat.' : hrs >= 1 ? ' — ${niceHours(hrs)} of it.' : '.';
    return 'That\'s $howMany${pick.$1 <= 1 ? ' round ' : ' '}${pick.$2}$afloat';
  }

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        color: t.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(children: [
            Icon(Icons.emoji_events_outlined, color: t.colorScheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600))),
          ]),
        ),
      );
}

class _MonthBars extends StatelessWidget {
  final List<Map> months;
  final ThemeData t;
  const _MonthBars(this.months, this.t);
  @override
  Widget build(BuildContext context) {
    final show = months.length > 12 ? months.sublist(months.length - 12) : months;
    var top = 0.0;
    for (final m in show) {
      top = top > (m['dist_nm'] as num) ? top : (m['dist_nm'] as num).toDouble();
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          for (final m in show)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 52, child: Text(niceMonth('${m['month']}'), style: t.textTheme.bodySmall)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: top > 0 ? (m['dist_nm'] as num) / top : 0, minHeight: 14, backgroundColor: t.colorScheme.surfaceContainerHighest),
                  ),
                ),
                SizedBox(width: 74, child: Text('${nm(m['dist_nm'] as num)} nm', textAlign: TextAlign.right, style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
              ]),
            ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- League

class _LeagueTab extends StatefulWidget {
  const _LeagueTab();
  @override
  State<_LeagueTab> createState() => _LeagueTabState();
}

enum _Cat {
  miles('Miles', 'dist_nm', Icons.route_outlined),
  hours('Hours', 'moving_h', Icons.timer_outlined),
  top('Top speed', 'max_kn', Icons.bolt),
  avg('Best average', 'best_avg_kn', Icons.speed);

  final String label, key;
  final IconData icon;
  const _Cat(this.label, this.key, this.icon);

  String fmt(num v) => switch (this) {
        _Cat.miles => '${nm(v)} nm',
        _Cat.hours => niceHours(v),
        _Cat.top || _Cat.avg => '${v.toStringAsFixed(1)} kn',
      };
}

class _LeagueTabState extends State<_LeagueTab> {
  String _period = 'all';
  _Cat _cat = _Cat.miles;
  List<Map<String, dynamic>>? _people;
  String? _err, _source;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
    app.addListener(_load);
  }

  @override
  void dispose() {
    app.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final n = ++_req;
    final period = _period;
    List<Map<String, dynamic>>? people;
    String? err, src;
    final sync = serverOrNull();
    if (sync != null) {
      try {
        people = await sync.league(period);
        src = 'you and your friends, from the server';
      } on SyncException catch (e) {
        err = e.message;
      }
    }
    if (people == null) {
      try {
        people = (((await app.store.leagueTable(period))['people']) as List).cast<Map<String, dynamic>>();
        src = sync == null ? 'the tracks on this phone' : 'the tracks on this phone (${err ?? 'server not reached'})';
        err = null;
      } catch (e) {
        err = '$e';
      }
    }
    if (mounted && n == _req && period == _period) {
      setState(() {
        _people = people;
        _err = err;
        _source = src;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final people = _people;
    List<Map<String, dynamic>>? ranked;
    if (people != null) {
      ranked = people.where((p) => ((p[_cat.key] as num?) ?? 0) > 0).toList()
        ..sort((a, b) => ((b[_cat.key] as num?) ?? 0).compareTo((a[_cat.key] as num?) ?? 0));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 24), children: [
        Center(
          child: _PeriodPicker(_period, (p) {
            setState(() {
              _period = p;
              _people = null;
            });
            _load();
          }),
        ),
        const SizedBox(height: 10),
        Center(
          child: SegmentedButton<_Cat>(
            showSelectedIcon: false,
            segments: [for (final c in _Cat.values) ButtonSegment(value: c, icon: Icon(c.icon, size: 16), label: Text(c.label))],
            selected: {_cat},
            onSelectionChanged: (s) => setState(() => _cat = s.first),
          ),
        ),
        const SizedBox(height: 12),
        if (ranked == null && _err != null) _Empty(Icons.error_outline, 'Couldn\'t load the league', _err!),
        if (ranked == null && _err == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (ranked != null && ranked.isEmpty)
          _Empty(Icons.emoji_events_outlined, 'No one on the board yet',
              app.signedIn ? 'Sync your sessions and add friends (Setup → Friends): everyone\'s shared sails count here.' : 'Sign in (Setup → You) to race your friends for miles, hours and speed.'),
        if (ranked != null)
          for (var i = 0; i < ranked.length; i++) _row(t, i, ranked[i]),
        if (_source != null) ...[
          const SizedBox(height: 16),
          Center(child: Hint('Counting $_source. Private sessions stay off the board.')),
        ],
      ]),
    );
  }

  Widget _row(ThemeData t, int i, Map<String, dynamic> p) {
    final me = p['me'] == true;
    final medal = switch (i) { 0 => '🥇', 1 => '🥈', 2 => '🥉', _ => '' };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: me ? t.colorScheme.primaryContainer : null,
      child: ListTile(
        leading: SizedBox(
          width: 40,
          child: Center(
            child: medal.isNotEmpty
                ? Text(medal, style: const TextStyle(fontSize: 24))
                : Text('${i + 1}', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        ),
        title: Text('${p['name']}${me ? ' (you)' : ''}', style: TextStyle(fontWeight: me ? FontWeight.w800 : FontWeight.w600)),
        subtitle: Text('${p['sessions']} session${p['sessions'] == 1 ? '' : 's'} · ${nm((p['dist_nm'] as num?) ?? 0)} nm · ${niceHours((p['moving_h'] as num?) ?? 0)}'),
        trailing: Text(_cat.fmt((p[_cat.key] as num?) ?? 0), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      ),
    );
  }
}
