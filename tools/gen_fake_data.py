#!/usr/bin/env python3
"""Generate fake puck logs for demoing the WakeBack viewer.

Writes CSV files in the exact format the puck firmware will produce:
    t_ms,lat,lon,sog_kn,hdg,heel,pitch
plus one GPX file as if it came from a mate's phone.

Usage:  python tools/gen_fake_data.py            # writes into data/sessions/
        python tools/gen_fake_data.py --out /tmp/x
"""
import argparse, json, math, random, os
from datetime import datetime, timezone, timedelta

KN = 1.943844                      # m/s -> knots
CENTRE = (53.6503, -3.0102)        # Marine Lake, Southport (approximate)

def rad(d): return d * math.pi / 180

def sim_boat(base_kn, seed, start_offset, heel_up, wind=25, t0=None, laps=3):
    R = random.Random(seed)
    u = (math.sin(rad(wind)), math.cos(rad(wind)))       # upwind unit vector
    v = (math.cos(rad(wind)), -math.sin(rad(wind)))      # across-wind unit vector
    mk = lambda a, c: (u[0]*a + v[0]*c, u[1]*a + v[1]*c)
    marks = [mk(380, 10), mk(-360, 45), mk(-120, -45)]
    x, y = marks[2][0] + start_offset, marks[2][1] - 15
    side, tack_t, mi, lap, dside = 1, -99, 0, 0, 1
    dt, s, rows = 0.1, 0.0, []
    while s < 3*3600 and lap < laps:
        tx, ty = marks[mi][0]-x, marks[mi][1]-y
        d = math.hypot(tx, ty)
        if d < 12:
            mi = (mi+1) % 3
            if mi == 0: lap += 1
            continue
        want = (math.degrees(math.atan2(tx, ty)) + 360) % 360
        diff = ((want - wind + 540) % 360) - 180
        if abs(diff) < 42:                                   # beating
            lat_off = x*v[0] + y*v[1]
            if lat_off*side > 60: side, tack_t = -side, s
            hdg, k, heel, pitch = wind + side*42, 0.82, side*heel_up, -1   # port tack (TWA>0) heels to starboard (+)
        elif abs(diff) > 140:                               # run: sail by the lee-ish angles and gybe down the leg
            lat_off = x*v[0] + y*v[1] - (marks[mi][0]*v[0] + marks[mi][1]*v[1])
            if lat_off*dside > 35: dside, tack_t = -dside, s
            hdg, k, heel, pitch = wind + 180 - dside*22, 0.95, -dside*heel_up*0.25, 3
        else:
            hdg, k = want, 1.15
            sgn = 1 if diff > 0 else -1
            heel, pitch = sgn*heel_up*0.7, 0.5
        since = s - tack_t
        if since < 8:
            k *= 0.55 + 0.45*since/8
            heel *= since/8
        heel += 2.5*math.sin(s/3.1+seed) + 1.5*(R.random()-0.5)
        pitch += 1.2*math.sin(s/2.3+seed) + 0.8*(R.random()-0.5)
        kn = base_kn*k*(1 + 0.07*math.sin(s/9+seed) + 0.06*(R.random()-0.5))
        ms = kn/KN
        x += math.sin(rad(hdg))*ms*dt
        y += math.cos(rad(hdg))*ms*dt
        nx, ny = x + (R.random()-0.5)*1.2, y + (R.random()-0.5)*1.2
        lat = CENTRE[0] + ny/111320
        lon = CENTRE[1] + nx/(111320*math.cos(rad(CENTRE[0])))
        rows.append((t0 + timedelta(seconds=s), lat, lon, kn + 0.05*(R.random()-0.5), hdg % 360, heel, pitch))
        s += dt
    return rows

def drift(a, b, R, dt=0.1):
    """Rows for a boat drifting slowly from the last row of a to the first row of b (between races)."""
    t0, lat0, lon0 = a[-1][0], a[-1][1], a[-1][2]
    t1, lat1, lon1 = b[0][0], b[0][1], b[0][2]
    n = int((t1 - t0).total_seconds() / dt)
    rows, hdg = [], R.random() * 360
    for k in range(1, n):
        f = k / n
        hdg = (hdg + (R.random() - 0.5) * 4) % 360
        rows.append((t0 + timedelta(seconds=k*dt),
                     lat0 + (lat1-lat0)*f + (R.random()-0.5)*2e-5,
                     lon0 + (lon1-lon0)*f + (R.random()-0.5)*3e-5,
                     0.3 + 0.5*R.random(), hdg, (R.random()-0.5)*3, (R.random()-0.5)*2))
    return rows

def two_races(base_kn, seed, offset, heel, t0, gap_min=14):
    """Race 1 (3 laps), drift about for a bit, race 2 (2 laps, different seed). One log file, like a real morning."""
    r1 = sim_boat(base_kn, seed, offset, heel, t0=t0, laps=3)
    start2 = t0 + timedelta(minutes=57)          # one gun for the whole fleet
    assert start2 > r1[-1][0] + timedelta(minutes=5), 'race 1 ran too long for the gap'
    r2 = sim_boat(base_kn * 0.97, seed + 100, -offset, heel, t0=start2, laps=2)
    return r1 + drift(r1, r2, random.Random(seed)) + r2

def write_csv(path, rows):
    with open(path, 'w') as f:
        f.write('t_ms,lat,lon,sog_kn,hdg,heel,pitch\n')
        for t, lat, lon, sog, hdg, heel, pitch in rows:
            f.write(f'{int(t.timestamp()*1000)},{lat:.7f},{lon:.7f},{sog:.2f},{hdg:.0f},{heel:.1f},{pitch:.1f}\n')

def write_gpx(path, name, rows, every=10):
    with open(path, 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="phone" xmlns="http://www.topografix.com/GPX/1/1">\n')
        f.write(f'<trk><name>{name}</name><trkseg>\n')
        for t, lat, lon, *_ in rows[::every]:            # phones log at 1 Hz
            f.write(f'<trkpt lat="{lat:.6f}" lon="{lon:.6f}"><time>{t.strftime("%Y-%m-%dT%H:%M:%SZ")}</time></trkpt>\n')
        f.write('</trkseg></trk>\n</gpx>\n')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'data', 'sessions'))
    a = ap.parse_args()

    # Sunday: two back-to-back races in one log per puck, plus one phone track. Try "Auto split" on this one.
    day = datetime(2026, 9, 20, 10, 30, tzinfo=timezone.utc)
    d = os.path.join(a.out, day.strftime('%Y-%m-%d')); os.makedirs(d, exist_ok=True)
    fleet = [('puck1', 4.6, 11,  0, 12), ('puck2', 4.4, 23,  8,  5), ('puck3', 4.2, 37, -8, 24)]
    for puck, kn, seed, off, heel in fleet:
        write_csv(os.path.join(d, f'{puck}_{day.strftime("%H%M%S")}.csv'), two_races(kn, seed, off, heel, day))
    write_gpx(os.path.join(d, 'Steve_phone.gpx'), 'Steve', two_races(4.3, 51, 20, 15, day))
    # the course that was laid: same marks the boats sail round, clockwise, so all left to starboard (green)
    wind = 25
    u = (math.sin(rad(wind)), math.cos(rad(wind))); v = (math.cos(rad(wind)), -math.sin(rad(wind)))
    marks = []
    for name, (a_, c_) in [('Windward', (380, 10)), ('Leeward', (-360, 45)), ('Mark 3', (-120, -45))]:
        x, y = u[0]*a_ + v[0]*c_, u[1]*a_ + v[1]*c_
        marks.append({'id': name.lower().replace(' ', ''), 'name': name, 'side': 'stbd',
                      'lat': CENTRE[0] + y/111320, 'lon': CENTRE[1] + x/(111320*math.cos(rad(CENTRE[0])))})
    # start line just upwind of where the boats set off (committee boat at the starboard end), finish line just below Mark 3
    ll = lambda x, y: {'lat': CENTRE[0] + y/111320, 'lon': CENTRE[1] + x/(111320*math.cos(rad(CENTRE[0])))}
    m3 = (u[0]*-120 + v[0]*-45, u[1]*-120 + v[1]*-45)
    sc = (m3[0] + u[0]*6, m3[1] - 15 + u[1]*6); fc = (m3[0] - u[0]*18, m3[1] - u[1]*18)
    lines = [
        {'id': 'start', 'kind': 'start', 'a': ll(sc[0] + v[0]*35, sc[1] + v[1]*35), 'b': ll(sc[0] - v[0]*35, sc[1] - v[1]*35)},
        {'id': 'finish', 'kind': 'finish', 'a': ll(fc[0] + v[0]*30, fc[1] + v[1]*30), 'b': ll(fc[0] - v[0]*30, fc[1] - v[1]*30)},
    ]
    with open(os.path.join(d, 'meta.json'), 'w') as f:
        json.dump({'marks': marks, 'fixes': [], 'lines': lines}, f, indent=1)

    # Tuesday training: one puck, a couple of laps on its own, different wind
    day2 = datetime(2026, 9, 22, 17, 45, tzinfo=timezone.utc)
    d2 = os.path.join(a.out, day2.strftime('%Y-%m-%d')); os.makedirs(d2, exist_ok=True)
    write_csv(os.path.join(d2, f'puck1_{day2.strftime("%H%M%S")}.csv'), sim_boat(4.7, 71, 0, 10, wind=300, t0=day2, laps=2))
    print('wrote fake sessions to', os.path.abspath(a.out))

if __name__ == '__main__':
    main()
