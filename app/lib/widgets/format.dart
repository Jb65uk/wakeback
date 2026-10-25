// Dates the way a sailor reads them: 'Sun 20 Sep 2026', 'Sep 26', '20 Sep'. One place for the month names.

const shortMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const shortDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// 'Sun 20 Sep 2026'
String niceDay(DateTime d) => '${shortDays[d.weekday - 1]} ${d.day} ${shortMonths[d.month - 1]} ${d.year}';

/// '2026-09-20' -> 'Sun 20 Sep 2026'
String niceDate(String ymd) {
  try {
    return niceDay(DateTime.parse(ymd));
  } catch (_) {
    return ymd;
  }
}

/// '2026-09' -> 'Sep 26'
String niceMonth(String ym) {
  try {
    final p = ym.split('-');
    return '${shortMonths[int.parse(p[1]) - 1]} ${p[0].substring(2)}';
  } catch (_) {
    return ym;
  }
}

/// A moment in time, as '20 Sep'.
String dayMonth(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${shortMonths[d.month - 1]}';
}
