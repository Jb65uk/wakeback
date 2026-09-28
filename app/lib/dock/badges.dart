// Personal bests and badges, worked out from your own tracks (StatRow) — nothing stored but "seen".
import 'stats.dart';

/// A new personal best set by a track that's just arrived.
class PersonalBest {
  final String title, value; // "Top speed", "6.8 kn"
  final String scope; // "ever" or "this year"
  final StatRow track;
  const PersonalBest(this.title, this.value, this.scope, this.track);
  Map<String, dynamic> toJson() => {'title': title, 'value': value, 'scope': scope, 'session': track.session, 'file': track.file, 'date': track.date};
}

String _kn(num v) => '${v.toStringAsFixed(1)} kn';
String _nm(num v) => '${v.toStringAsFixed(1)} nm';
String _h(num s) => s >= 3600 ? '${(s / 3600).toStringAsFixed(1)} h' : '${(s / 60).round()} min';

/// What the tracks in [fresh] beat, compared with everything in [before] (your earlier tracks).
List<PersonalBest> newRecords(List<StatRow> fresh, List<StatRow> before, {int? year}) {
  final out = <PersonalBest>[];
  final yr = (year ?? DateTime.now().year).toString();
  final cats = <(String, String, num? Function(StatRow), String Function(num))>[
    ('Top speed', 'max_kn', (r) => r.stats['max_kn'] as num?, _kn),
    ('Fastest average', 'avg_kn', (r) => r.stats['avg_kn'] as num?, _kn),
    ('Longest sail', 'dist_nm', (r) => r.stats['dist_nm'] as num?, _nm),
    ('Longest time on the water', 'moving_s', (r) => r.stats['moving_s'] as num?, _h),
    ('Best upwind VMG', 'vmg_kn', (r) => r.stats['vmg_kn'] as num?, _kn),
  ];
  for (final (title, _, get, fmt) in cats) {
    // the best of the new tracks in this category
    StatRow? best;
    for (final r in fresh) {
      final v = get(r);
      if (v != null && v > 0 && (best == null || v > get(best)!)) best = r;
    }
    if (best == null) continue;
    final v = get(best)!;
    num prevEver = 0, prevYear = 0;
    for (final r in before) {
      final p = get(r);
      if (p == null) continue;
      if (p > prevEver) prevEver = p;
      if (r.date.startsWith(yr) && p > prevYear) prevYear = p;
    }
    if (before.isEmpty) continue; // nothing to beat yet: the first sail is its own badge
    if (v > prevEver) {
      out.add(PersonalBest(title, fmt(v), 'ever', best));
    } else if (best.date.startsWith(yr) && v > prevYear) {
      out.add(PersonalBest(title, fmt(v), 'this year', best));
    }
  }
  return out;
}

class SailBadge {
  final String id, name, icon, blurb; // icon: an emoji
  final bool earned;
  final String? detail; // when earned: what did it
  const SailBadge(this.id, this.name, this.icon, this.blurb, this.earned, [this.detail]);
}

/// Every badge, earned or not, from your tracks and their summary (stats.summarise).
List<SailBadge> badges(List<StatRow> rows, Map<String, dynamic> sum) {
  if (rows.isEmpty) {
    return const [
      SailBadge('first', 'First splash', '🌊', 'Your first sail', false),
    ];
  }
  final sessions = (sum['sessions'] as num?)?.toInt() ?? 0;
  final dist = (sum['dist_nm'] as num?)?.toDouble() ?? 0;
  final maxKn = (sum['max_kn'] as num?)?.toDouble() ?? 0;
  final months = ((sum['by_month'] as List?) ?? const []).whereType<Map>().toList();
  Map? bigMonth;
  for (final m in months) {
    if ((m['dist_nm'] as num) >= 100 && (bigMonth == null || (m['dist_nm'] as num) > (bigMonth['dist_nm'] as num))) bigMonth = m;
  }
  StatRow? longest, longestDay, dawn, windy, swimmer, early;
  for (final r in rows) {
    if (longest == null || r.distNm > longest.distNm) longest = r;
    if (longestDay == null || r.movingS > longestDay.movingS) longestDay = r;
    final start = DateTime.fromMillisecondsSinceEpoch(r.startMs).toLocal();
    if (start.hour < 7 && (dawn == null || start.hour < DateTime.fromMillisecondsSinceEpoch(dawn.startMs).toLocal().hour)) dawn = r;
    final w = (r.stats['wind_kn'] as num?)?.toDouble();
    if (w != null && w >= 20 && (windy == null || w > (windy.stats['wind_kn'] as num))) windy = r;
    if (((r.stats['capsizes'] as num?) ?? 0) > 0 && swimmer == null) swimmer = r;
    if (early == null || r.date.compareTo(early.date) < 0) early = r;
  }
  // weekends in a row with a sail (Sat or Sun): longest run
  final weekends = <int>{};
  for (final r in rows) {
    final d = DateTime.parse(r.date);
    final u = DateTime.utc(d.year, d.month, d.day); // UTC, so a clock change can't lose a week
    if (u.weekday == DateTime.saturday || u.weekday == DateTime.sunday) {
      final sat = u.subtract(Duration(days: u.weekday == DateTime.sunday ? 1 : 0));
      weekends.add(sat.difference(DateTime.utc(2000, 1, 1)).inDays ~/ 7);
    }
  }
  var streak = 0, run = 0;
  int? last;
  for (final w in weekends.toList()..sort()) {
    run = (last != null && w == last + 1) ? run + 1 : 1;
    if (run > streak) streak = run;
    last = w;
  }
  final venues = (sum['venues'] as num?)?.toInt() ?? 0;
  String when(StatRow? r) => r == null ? '' : '${r.date} · ${r.venueName}';
  return [
    SailBadge('first', 'First splash', '🌊', 'Your first sail', true, when(early)),
    SailBadge('ten', 'Regular', '📅', '10 sessions', sessions >= 10, sessions >= 10 ? '$sessions sessions' : '$sessions of 10'),
    SailBadge('fifty', 'Fixture', '🏛️', '50 sessions', sessions >= 50, sessions >= 50 ? '$sessions sessions' : '$sessions of 50'),
    SailBadge('kn6', 'Six knots', '💨', 'Top speed over 6 kn', maxKn >= 6, maxKn >= 6 ? _kn(maxKn) : 'best so far ${_kn(maxKn)}'),
    SailBadge('kn8', 'Planing', '🚀', 'Top speed over 8 kn', maxKn >= 8, maxKn >= 8 ? _kn(maxKn) : 'best so far ${_kn(maxKn)}'),
    SailBadge('kn10', 'Double figures', '⚡', 'Top speed over 10 kn', maxKn >= 10, maxKn >= 10 ? _kn(maxKn) : 'best so far ${_kn(maxKn)}'),
    SailBadge('nm100', 'Century', '💯', '100 nautical miles in all', dist >= 100, dist >= 100 ? _nm(dist) : '${_nm(dist)} of 100'),
    SailBadge('nm500', 'Round the Island x10', '🏝️', '500 nautical miles in all', dist >= 500, dist >= 500 ? _nm(dist) : '${_nm(dist)} of 500'),
    SailBadge('month100', 'Big month', '📈', '100 nm in one month', bigMonth != null, bigMonth == null ? null : '${bigMonth['month']}: ${_nm(bigMonth['dist_nm'] as num)}'),
    SailBadge('marathon', 'Marathon', '🏃', '15 nm in one sail', (longest?.distNm ?? 0) >= 15, longest == null ? null : '${_nm(longest.distNm)} · ${when(longest)}'),
    SailBadge('allday', 'All day', '☀️', '4 hours on the water in one sail', (longestDay?.movingS ?? 0) >= 4 * 3600, longestDay == null ? null : '${_h(longestDay.movingS)} · ${when(longestDay)}'),
    SailBadge('dawn', 'Dawn patrol', '🌅', 'On the water before 7 am', dawn != null, when(dawn)),
    SailBadge('streak3', 'Three in a row', '🔥', 'Three weekends running', streak >= 3, streak >= 3 ? '$streak weekends' : '$streak so far'),
    SailBadge('streak6', 'Season regular', '🏆', 'Six weekends running', streak >= 6, streak >= 6 ? '$streak weekends' : '$streak so far'),
    SailBadge('explorer', 'Explorer', '🧭', 'Sailed at 3 venues', venues >= 3, '$venues venue${venues == 1 ? '' : 's'}'),
    SailBadge('windy', 'Blowing a hoolie', '🌬️', 'Sailed in 20 kn or more', windy != null, windy == null ? null : '${(windy.stats['wind_kn'] as num).toStringAsFixed(0)} kn · ${when(windy)}'),
    SailBadge('swimmer', 'Swimmer', '🏊', 'Capsized (the puck knows)', swimmer != null, when(swimmer)),
  ];
}
