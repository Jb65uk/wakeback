#!/usr/bin/env python3
"""Pretend to be a dock full of pucks, so the Dock page has something to show.

What it does (Ctrl+C to stop):
  P1  on the pad, full
  P2  on the pad, charging up from 64%
  P3  on the pad, charging from low (28%)
  P4  out sailing; comes back after ~20 s, uploads a short session, then charges
  P5  on the pad but its charger isn't working (battery slowly dropping)
  P6  has never checked in (shows when the dock runs with WAKEBACK_FLEET=6)

Usage: python tools/fake_pucks.py [--dock http://localhost:5000] [--fast] [--key <puck key>]
"""
import argparse, json, os, random, sys, time, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_fake_data import sim_boat, write_csv   # reuse the boat simulator
from fake_puck_upload import upload

ap = argparse.ArgumentParser()
ap.add_argument('--dock', default='http://localhost:5000')
ap.add_argument('--fast', action='store_true', help='check in every 3 s instead of 30 s (for demos)')
ap.add_argument('--key', default='', help='X-Puck-Key sent with every check-in and upload (a key the app issued for puck 4, if the server has accounts on)')
a = ap.parse_args()
EVERY = 3 if a.fast else 30

def post_json(path, body):
    headers = {'Content-Type': 'application/json'}
    if a.key: headers['X-Puck-Key'] = a.key
    req = urllib.request.Request(a.dock + path, data=json.dumps(body).encode(), method='POST', headers=headers)
    with urllib.request.urlopen(req, timeout=5) as r: return json.loads(r.read())

def mv_for(pct):
    # rough inverse of the dock's LiPo table
    table = [(100, 4200), (90, 4100), (78, 4000), (62, 3900), (45, 3800), (35, 3750), (22, 3700), (12, 3650), (6, 3600), (0, 3300)]
    for (p1, v1), (p2, v2) in zip(table, table[1:]):
        if pct >= p2: return int(v2 + (v1 - v2) * (pct - p2) / (p1 - p2))
    return 3300

pucks = {
    1: dict(pct=100, state='full',     on_pad=True,  fw='0.3.1', free=14100),
    2: dict(pct=64,  state='charging', on_pad=True,  fw='0.3.1', free=13900),
    3: dict(pct=28,  state='charging', on_pad=True,  fw='0.3.0', free=12200),
    4: dict(pct=71,  state='not',      on_pad=False, fw='0.3.1', free=13000, back_in=20),
    5: dict(pct=47,  state='not',      on_pad=True,  fw='0.3.1', free=14000),
}
start = time.time()
# P4 was lifted off the pad this morning: a puck says so as it leaves, so the dock knows it's away rather than lost
try: post_json('/api/pucks/checkin', dict(puck=4, battery_mv=mv_for(98), charging='not', on_pad=False, free_kb=13000, total_kb=14336, fw='0.3.1'))
except OSError as e: sys.exit(f'dock not reachable at {a.dock}: {e}')
print(f'Fake pucks checking in to {a.dock} every {EVERY} s. P6 never checks in. Ctrl+C to stop.')
try:
    while True:
        for n, p in pucks.items():
            if not p['on_pad']:
                if 'back_in' in p and time.time() - start > p['back_in']:
                    # P4 comes ashore: dock, upload today's training session, start charging
                    p['on_pad'] = True; p['state'] = 'charging'; del p['back_in']
                    t0 = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(minutes=50)
                    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'puck{n}_{t0.strftime("%H%M%S")}.csv')
                    write_csv(path, sim_boat(4.5, random.randint(1, 999), 0, 12, wind=260, t0=t0, laps=1))
                    try:
                        post_json('/api/pucks/checkin', dict(puck=n, battery_mv=mv_for(p['pct']), charging='charging', on_pad=True, free_kb=p['free'], total_kb=14336, fw=p['fw'], pending=1))
                        r = upload(path, a.dock, n, a.key); print(f'P{n} docked and uploaded {r.get("file")} to {r.get("session")}')
                    except urllib.error.HTTPError as e:
                        # the server said no (401 without a key when accounts are on): the other pucks carry on
                        print(f'P{n} upload refused: {e.code} {e.read().decode(errors="replace").strip()}')
                    finally:
                        os.remove(path)
                continue
            if p['state'] == 'charging':
                p['pct'] = min(100, p['pct'] + (1.5 if a.fast else 0.5))
                if p['pct'] >= 100: p['state'] = 'full'
            elif p['state'] == 'not':
                p['pct'] = max(0, p['pct'] - 0.05)
            try:
                post_json('/api/pucks/checkin', dict(puck=n, battery_mv=mv_for(p['pct']), charging=p['state'], on_pad=True,
                                                   free_kb=p['free'], total_kb=14336, fw=p['fw'], pending=0, rssi=random.randint(-60, -40)))
            except urllib.error.HTTPError as e:
                print(f'P{n} check-in refused: {e.code}')
            except OSError as e:
                print(f'dock not reachable: {e}'); break
        time.sleep(EVERY)
except KeyboardInterrupt:
    print('stopped')
