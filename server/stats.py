"""Track statistics for WakeBack: per-track numbers, your totals, and the friends' league.

Same numbers as the viewer's boat list: distance from the track while moving (> 0.5 kn), top speed
is the 99.5th percentile of speed (so one GPS spike doesn't win), average speed is the mean while
moving (> 1 kn), time on the water counts samples over 1.5 kn.

Per-track stats are cached in each session folder's stats.json (keyed by file name + size), so a
day's folder is only parsed once. The phone app computes exactly the same (app/lib/dock/store.dart).
"""
import math, os, re, json
from datetime import datetime, timezone

KN = 1.943844
CACHE_V = 2   # bump when compute_stats learns something new, so old stats.json files are redone


def _hav_m(la1, lo1, la2, lo2):
    r = math.radians
    h = math.sin(r(la2 - la1) / 2) ** 2 + math.cos(r(la1)) * math.cos(r(la2)) * math.sin(r(lo2 - lo1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(max(0.0, min(1.0, h))))


def _parse_time(s):
    s = s.strip()
    try:
        return int(datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp() * 1000)
    except ValueError:
        return None


def _points(path):
    """[(t_ms, lat, lon, sog_kn or None, hdg or None, heel or None)] from a puck CSV or a GPX file."""
    pts = []
    with open(path, 'r', errors='ignore') as f:
        text = f.read()
    if path.lower().endswith('.gpx'):
        for m in re.finditer(r'<trkpt\b([^>]*)>(.*?)</trkpt>', text, re.S):
            la = re.search(r'\blat="([-0-9.]+)"', m.group(1)); lo = re.search(r'\blon="([-0-9.]+)"', m.group(1))
            tm = re.search(r'<time>([^<]+)</time>', m.group(2))
            if not (la and lo and tm): continue
            t = _parse_time(tm.group(1))
            if t is None: continue
            sp = re.search(r'<(?:gpxtpx:)?speed>([-0-9.eE]+)</', m.group(2))
            sog = float(sp.group(1)) * KN if sp else None
            pts.append((t, float(la.group(1)), float(lo.group(1)), sog, None, None))
    else:
        lines = text.splitlines()
        if not lines: return []
        cols = [c.strip().lower() for c in lines[0].split(',')]
        try:
            it, ila, ilo = cols.index('t_ms'), cols.index('lat'), cols.index('lon')
        except ValueError:
            return []
        isog = cols.index('sog_kn') if 'sog_kn' in cols else -1
        ihdg = cols.index('hdg') if 'hdg' in cols else -1
        iheel = cols.index('heel') if 'heel' in cols else -1
        def opt(c, i):
            try: return float(c[i]) if i >= 0 and i < len(c) and c[i] != '' else None
            except ValueError: return None
        for ln in lines[1:]:
            c = ln.split(',')
            try:
                t = float(c[it]); lat, lon = float(c[ila]), float(c[ilo])
                if t < 1e12: t *= 1000
                sog = float(c[isog]) if isog >= 0 and isog < len(c) and c[isog] else None
            except (ValueError, IndexError):
                continue
            if not (-90 <= lat <= 90 and -180 <= lon <= 180): continue
            pts.append((int(t), lat, lon, sog, opt(c, ihdg), opt(c, iheel)))
    pts.sort(key=lambda p: p[0])
    return pts


def _bearing(la1, lo1, la2, lo2):
    r = math.radians
    y = math.sin(r(lo2 - lo1)) * math.cos(r(la2))
    x = math.cos(r(la1)) * math.sin(r(la2)) - math.sin(r(la1)) * math.cos(r(la2)) * math.cos(r(lo2 - lo1))
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def wind_at(weather, t_ms):
    """(dir_from_deg, speed_kn) from the day's hourly weather (meta.weather), nearest hour, or None."""
    pts = weather.get('pts') if isinstance(weather, dict) else None
    if not pts: return None
    best = min(pts, key=lambda p: abs(p[0] - t_ms))
    if abs(best[0] - t_ms) > 2 * 3600 * 1000: return None
    return (best[1], best[2])


def compute_stats(path, weather=None):
    """Stats for one track file, or None if it has no usable positions.
    With the day's weather: upwind/downwind averages, best VMG and the wind strength it was sailed in."""
    pts = _points(path)
    if len(pts) < 2: return None
    # speed: from the file when it has it (pucks), else from consecutive positions (phones/watches)
    sog = []
    for i, p in enumerate(pts):
        if p[3] is not None:
            sog.append(p[3])
        elif i == 0:
            sog.append(0.0)
        else:
            dt = (p[0] - pts[i - 1][0]) / 1000
            sog.append(_hav_m(pts[i - 1][1], pts[i - 1][2], p[1], p[2]) / dt * KN if dt > 0 else 0.0)
    # smooth speed over ±1 s (at least the neighbours), like the viewer
    n = len(pts); pre = [0.0]
    for v in sog: pre.append(pre[-1] + v)
    sm = [0.0] * n; a = 0; b = 0
    for i in range(n):
        while pts[i][0] - pts[a][0] > 1000: a += 1
        while b + 1 < n and pts[b + 1][0] - pts[i][0] <= 1000: b += 1
        lo, hi = min(a, max(0, i - 1)), max(b, min(n - 1, i + 1))
        sm[i] = (pre[hi + 1] - pre[lo]) / (hi - lo + 1)
    sog = sm
    dist = 0.0; moving_ms = 0; s_sum = 0.0; s_cnt = 0
    for i in range(1, len(pts)):
        d = _hav_m(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2])
        dt = pts[i][0] - pts[i - 1][0]
        if dt <= 0 or dt > 60000: continue                 # gap in the log: don't count it
        if d / (dt / 1000) > 40: continue                  # > ~80 kn between fixes = a glitch
        if sog[i] > 0.5: dist += d
        if sog[i] > 1: s_sum += sog[i]; s_cnt += 1
        if sog[i] > 1.5: moving_ms += dt
    vals = sorted(sog)
    out = {
        'points': len(pts), 'start_ms': pts[0][0], 'end_ms': pts[-1][0],
        'dist_nm': round(dist / 1852, 3),
        'max_kn': round(vals[min(len(vals) - 1, int(len(vals) * 0.995))], 2),
        'avg_kn': round(s_sum / s_cnt, 2) if s_cnt else 0.0,
        'moving_s': moving_ms // 1000,
    }
    # heel (pucks only): 99th percentile of |heel|, and capsizes = |heel| > 80 deg for 10 s or more
    heels = [abs(p[5]) for p in pts if p[5] is not None]
    if heels:
        hs = sorted(heels)
        out['max_heel'] = round(hs[min(len(hs) - 1, int(len(hs) * 0.99))], 1)
        caps = 0; run_start = None; over = False
        for p in pts:
            if p[5] is not None and abs(p[5]) > 80:
                if run_start is None: run_start = p[0]; over = False
                if not over and p[0] - run_start >= 10000: caps += 1; over = True
            else:
                run_start = None
        out['capsizes'] = caps
    # the wind: heading vs the hour's wind direction while moving
    if weather:
        up = []; down = []; wkn = []; vmg = []
        for i in range(1, n):
            if sog[i] <= 1: continue
            w = wind_at(weather, pts[i][0])
            if w is None: continue
            hdg = pts[i][4]
            if hdg is None:
                if pts[i][0] - pts[i - 1][0] <= 0: continue
                hdg = _bearing(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2])
            ang = abs((hdg - w[0] + 180) % 360 - 180)      # 0 = straight into the wind
            wkn.append(w[1])
            if ang < 60: up.append(sog[i]); vmg.append((pts[i][0], sog[i] * math.cos(math.radians(ang))))
            elif ang > 120: down.append(sog[i])
        if wkn:
            out['wind_kn'] = round(sum(wkn) / len(wkn), 1)
            if up: out['up_kn'] = round(sum(up) / len(up), 2)
            if down: out['down_kn'] = round(sum(down) / len(down), 2)
            # best upwind VMG over any 30 s
            best = 0.0; a = 0; acc = 0.0
            for b in range(len(vmg)):
                acc += vmg[b][1]
                while vmg[b][0] - vmg[a][0] > 30000: acc -= vmg[a][1]; a += 1
                if vmg[b][0] - vmg[a][0] >= 20000: best = max(best, acc / (b - a + 1))
            if best: out['vmg_kn'] = round(best, 2)
    return out


def session_stats(folder, files, lock=None):
    """{file: stats} for the tracks in a session folder, cached in stats.json
    (re-done if a file's size changed, or the day's weather was fetched since)."""
    cp = os.path.join(folder, 'stats.json')
    try:
        with open(cp) as f: cache = json.load(f)
        if not isinstance(cache, dict): cache = {}
    except (OSError, ValueError):
        cache = {}
    weather = None
    try:
        with open(os.path.join(folder, 'meta.json')) as f: weather = (json.load(f) or {}).get('weather') or None
    except (OSError, ValueError, AttributeError):
        pass
    wx_key = weather.get('got', 1) if isinstance(weather, dict) else 0
    out, changed = {}, False
    for fn in files:
        p = os.path.join(folder, fn)
        try: size = os.path.getsize(p)
        except OSError: continue
        c = cache.get(fn)
        if isinstance(c, dict) and c.get('_size') == size and c.get('_wx', 0) == wx_key and c.get('_v') == CACHE_V:
            if not c.get('_none'): out[fn] = {k: v for k, v in c.items() if not k.startswith('_')}
            continue
        st = compute_stats(p, weather)
        cache[fn] = {**(st or {}), '_size': size, '_wx': wx_key, '_v': CACHE_V, '_none': st is None}
        changed = True
        if st: out[fn] = st
    if changed:
        try:
            tmp = cp + '.tmp'
            # drop entries for tracks that have gone (not merely ones this viewer can't see)
            present = set(os.listdir(folder))
            with open(tmp, 'w') as f: json.dump({k: v for k, v in cache.items() if k in present}, f)
            os.replace(tmp, cp)
        except OSError:
            pass
    return out


def _month(ms):
    d = datetime.fromtimestamp(ms / 1000, timezone.utc)
    return f'{d.year:04d}-{d.month:02d}'


def period_start(period, now_ms=None):
    """'month' / 'year' / anything else = all time -> start in ms (UTC)."""
    now = datetime.fromtimestamp((now_ms or 0) / 1000, timezone.utc) if now_ms else datetime.now(timezone.utc)
    if period == 'month': return int(datetime(now.year, now.month, 1, tzinfo=timezone.utc).timestamp() * 1000)
    if period == 'year': return int(datetime(now.year, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
    return 0


WIND_BINS = ['0-5', '5-10', '10-15', '15-20', '20+']


def wind_bin(kn):
    return '0-5' if kn < 5 else '5-10' if kn < 10 else '10-15' if kn < 15 else '15-20' if kn < 20 else '20+'


def summarise(rows):
    """Totals for a list of {session, date, venue, venue_name, file, stats} rows (one person)."""
    if not rows:
        return {'sessions': 0, 'tracks': 0, 'dist_nm': 0.0, 'moving_h': 0.0, 'max_kn': 0.0, 'avg_kn': 0.0, 'best_avg_kn': 0.0}
    sessions = {r['session'] for r in rows}
    dist = sum(r['stats']['dist_nm'] for r in rows)
    moving = sum(r['stats']['moving_s'] for r in rows)
    fastest = max(rows, key=lambda r: r['stats']['max_kn'])
    best_avg = max(rows, key=lambda r: r['stats']['avg_kn'])
    longest = max(rows, key=lambda r: r['stats']['dist_nm'])
    # overall average: weighted by time moving
    w = sum(r['stats']['avg_kn'] * r['stats']['moving_s'] for r in rows)
    venues = {}
    for r in rows: venues[r['venue_name']] = venues.get(r['venue_name'], 0) + 1
    fav = max(venues.items(), key=lambda kv: kv[1])[0] if venues else None
    by_month = {}
    for r in rows:
        m = by_month.setdefault(_month(r['stats']['start_ms']), {'month': _month(r['stats']['start_ms']), 'dist_nm': 0.0, 'sessions': set(), 'moving_s': 0})
        m['dist_nm'] += r['stats']['dist_nm']; m['sessions'].add(r['session']); m['moving_s'] += r['stats']['moving_s']
    ref = lambda r: {'session': r['session'], 'file': r['file'], 'date': r['date'], 'venue_name': r['venue_name']}
    # the wind: sessions grouped by strength (Beaufort-ish bins), and upwind / downwind / VMG bests
    bins = {}
    for r in rows:
        st = r['stats']
        if 'wind_kn' not in st: continue
        k = wind_bin(st['wind_kn'])
        b = bins.setdefault(k, {'bin': k, 'sessions': set(), 'w': 0.0, 'moving_s': 0, 'best_avg_kn': 0.0, 'max_kn': 0.0})
        b['sessions'].add(r['session']); b['w'] += st['avg_kn'] * st['moving_s']; b['moving_s'] += st['moving_s']
        b['best_avg_kn'] = max(b['best_avg_kn'], st['avg_kn']); b['max_kn'] = max(b['max_kn'], st['max_kn'])
    wind = [{'bin': b['bin'], 'sessions': len(b['sessions']), 'avg_kn': round(b['w'] / b['moving_s'], 2) if b['moving_s'] else 0.0,
             'best_avg_kn': b['best_avg_kn'], 'max_kn': b['max_kn'], 'moving_h': round(b['moving_s'] / 3600, 2)}
            for b in sorted(bins.values(), key=lambda b: WIND_BINS.index(b['bin']))]
    def best_of(key):
        rs = [r for r in rows if key in r['stats']]
        return max(rs, key=lambda r: r['stats'][key]) if rs else None
    extra = {}
    for key in ('up_kn', 'down_kn', 'vmg_kn', 'max_heel'):
        b = best_of(key)
        if b: extra[key] = b['stats'][key]; extra[key.replace('_kn', '').replace('max_', '') + '_track'] = ref(b)
    ups = [r for r in rows if 'up_kn' in r['stats']]
    if ups:
        extra['avg_up_kn'] = round(sum(r['stats']['up_kn'] * r['stats']['moving_s'] for r in ups) / sum(r['stats']['moving_s'] for r in ups), 2)
    downs = [r for r in rows if 'down_kn' in r['stats']]
    if downs:
        extra['avg_down_kn'] = round(sum(r['stats']['down_kn'] * r['stats']['moving_s'] for r in downs) / sum(r['stats']['moving_s'] for r in downs), 2)
    extra['capsizes'] = sum(r['stats'].get('capsizes', 0) for r in rows)
    return {
        'wind': wind, **extra,
        'sessions': len(sessions), 'tracks': len(rows),
        'dist_nm': round(dist, 2), 'moving_h': round(moving / 3600, 2),
        'max_kn': fastest['stats']['max_kn'], 'max_track': ref(fastest),
        'avg_kn': round(w / moving, 2) if moving else 0.0,
        'best_avg_kn': best_avg['stats']['avg_kn'], 'best_avg_track': ref(best_avg),
        'longest_nm': longest['stats']['dist_nm'], 'longest_track': ref(longest),
        'venues': len(venues), 'favourite_venue': fav,
        'first_date': min(r['date'] for r in rows), 'last_date': max(r['date'] for r in rows),
        'by_month': sorted(({**m, 'dist_nm': round(m['dist_nm'], 2), 'sessions': len(m['sessions'])} for m in by_month.values()), key=lambda m: m['month']),
    }
