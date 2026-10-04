#!/usr/bin/env python3
"""Checks the server's account routes end to end, on a throwaway copy:  python tools/test_server.py
Covers: tiny tracks left out of stats, stats by boat, league by class, forgot password, export, delete account."""
import io, json, math, os, shutil, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp(prefix='wakeback_test_')
shutil.copytree(os.path.join(ROOT, 'server'), os.path.join(tmp, 'server'))
shutil.copytree(os.path.join(ROOT, 'viewer'), os.path.join(tmp, 'viewer'))
os.environ['WAKEBACK_ADMIN'] = 'admin@example.com'
os.environ.pop('WAKEBACK_ADMIN_RESET', None)
sys.path.insert(0, os.path.join(tmp, 'server'))
import app as wb, accounts        # noqa: E402

c = wb.app.test_client()
T0 = 1790000000000                # a fixed morning, ms


def track(minutes, kn=4.0, t0=T0, lat0=53.6503):
    """A straight sail north at `kn` for `minutes`, one fix a second, in the puck's CSV."""
    rows = ['t_ms,lat,lon,sog_kn']
    for s in range(int(minutes * 60) + 1):
        rows.append(f'{t0 + s * 1000},{lat0 + s * kn / 1.943844 / 111320:.7f},-3.0102,{kn}')
    return '\n'.join(rows).encode()


def signup(email, name, pw='password1'):
    r = c.post('/api/auth/signup', json={'email': email, 'name': name, 'password': pw})
    assert r.status_code in (200, 202), r.get_json()
    return r.get_json().get('token')


def H(tok): return {'Authorization': f'Bearer {tok}'}


def upload(tok, name, data, boat=''):
    r = c.post('/api/upload', headers=H(tok), data={'file': (io.BytesIO(data), name), 'boat': boat}, content_type='multipart/form-data')
    assert r.status_code == 200, r.get_json()
    return r.get_json()


try:
    admin = signup('admin@example.com', 'Admin')
    assert admin, 'the admin account is active straight away'
    c.put('/api/admin/settings', headers=H(admin), json={'auto_approve': True})
    james = signup('james@example.com', 'James')
    dave = signup('dave@example.com', 'Dave')
    c.delete_cookie('wb_token')

    # ---- tiny tracks: saved and replayable, but not in stats or the league
    upload(james, 'solo_am.csv', track(30, 4.0), boat='Solo 5843')
    upload(james, 'test_2min.csv', track(2, 3.0, t0=T0 + 4 * 3600_000), boat='Solo 5843')
    upload(james, 'mirror_pm.csv', track(20, 3.0, t0=T0 + 6 * 3600_000), boat='Mirror 70012')
    sess = c.get('/api/sessions', headers=H(james)).get_json()
    assert sum(len(s['files']) for s in sess) == 3, 'all three tracks are still there to replay'
    st = c.get('/api/stats', headers=H(james)).get_json()
    assert st['tracks'] == 2, st
    assert st['longest_track']['file'] == 'solo_am.csv'

    # ---- stats by boat
    assert st['boats'] == ['Mirror 70012', 'Solo 5843'], st['boats']
    solo = c.get('/api/stats?boat=solo 5843', headers=H(james)).get_json()
    assert solo['tracks'] == 1 and solo['boats'] == st['boats'] and abs(solo['dist_nm'] - 2.0) < 0.1, solo
    assert c.get('/api/stats?boat=Laser', headers=H(james)).get_json()['tracks'] == 0

    # ---- league by class: Dave's Solo counts with James's, by class not sail number
    upload(dave, 'dave.csv', track(40, 4.5, t0=T0 + 600_000), boat='Solo 5501')
    c.post('/api/friends/request', headers=H(james), json={'email': 'dave@example.com'})
    c.post('/api/friends/request', headers=H(dave), json={'email': 'james@example.com'})     # asking back = accepting
    lg = c.get('/api/league', headers=H(james)).get_json()
    assert lg['classes'] == ['Mirror', 'Solo'], lg['classes']
    assert {p['name'] for p in lg['people']} == {'James', 'Dave'}
    solos = c.get('/api/league?cls=Solo', headers=H(james)).get_json()['people']
    assert [p['name'] for p in solos] == ['Dave', 'James'] and abs(solos[1]['dist_nm'] - 2.0) < 0.1, solos
    mirrors = c.get('/api/league?cls=mirror', headers=H(james)).get_json()['people']
    assert [p['name'] for p in mirrors] == ['James']

    # ---- forgot password: ask, admin makes a code, the code works once
    assert c.post('/api/auth/forgot', json={'email': 'nobody@example.com'}).get_json()['ok'], 'no hint whether an account exists'
    assert c.post('/api/auth/forgot', json={'email': 'james@example.com'}).status_code == 200
    reqs = c.get('/api/admin/resets', headers=H(admin)).get_json()['resets']
    assert [r['email'] for r in reqs] == ['james@example.com'] and not reqs[0]['has_code']
    assert c.get('/api/admin/resets', headers=H(james)).status_code == 403
    r = c.post('/api/auth/reset', json={'email': 'james@example.com', 'code': 'AAAA-AAAA', 'new': 'newpassword'})
    assert r.status_code == 400, 'no code made yet'
    code = c.post(f"/api/admin/resets/{reqs[0]['id']}/code", headers=H(admin)).get_json()['code']
    assert len(code) == 9 and code[4] == '-'
    assert c.post('/api/auth/reset', json={'email': 'james@example.com', 'code': 'ZZZZ-ZZZZ', 'new': 'newpassword'}).status_code == 400
    assert c.post('/api/auth/reset', json={'email': 'james@example.com', 'code': code, 'new': 'short'}).status_code == 400
    assert c.post('/api/auth/reset', json={'email': 'james@example.com', 'code': code.lower().replace('-', ' '), 'new': 'newpassword'}).status_code == 200
    assert c.get('/api/stats', headers=H(james)).status_code == 401, 'old sign-ins are ended'
    assert c.post('/api/auth/reset', json={'email': 'james@example.com', 'code': code, 'new': 'another1234'}).status_code == 400, 'a code works once'
    assert c.post('/api/auth/login', json={'email': 'james@example.com', 'password': 'password1'}).status_code == 401
    james = c.post('/api/auth/login', json={'email': 'james@example.com', 'password': 'newpassword'}).get_json()['token']
    c.delete_cookie('wb_token')
    assert c.get('/api/admin/resets', headers=H(admin)).get_json()['resets'] == []

    # ---- export: account details and only your own tracks
    r = c.get('/api/me/export', headers=H(james))
    assert r.status_code == 200 and r.mimetype == 'application/zip'
    z = zipfile.ZipFile(io.BytesIO(r.data))
    names = sorted(z.namelist())
    assert [n.split('/')[-1] for n in names if n.startswith('tracks/')] == ['mirror_pm.csv', 'solo_am.csv', 'test_2min.csv'], names
    acc = json.loads(z.read('account.json'))
    assert acc['email'] == 'james@example.com' and acc['friends'] == ['Dave'] and len(acc['tracks']) == 3
    assert 'pw' not in acc and 'dave@example.com' not in z.read('account.json').decode(), 'no password hash, no friends\' emails'

    # ---- delete account: needs the password; takes the account and its tracks, leaves other people's
    assert c.delete('/api/me', headers=H(james), json={'password': 'wrong'}).status_code == 400
    assert c.delete('/api/me', headers=H(admin), json={'password': 'password1'}).status_code == 400, 'the admin can\'t delete itself'
    r = c.delete('/api/me', headers=H(james), json={'password': 'newpassword'})
    assert r.status_code == 200 and r.get_json()['tracks'] == 3, r.get_json()
    c.delete_cookie('wb_token')
    assert c.get('/api/stats', headers=H(james)).status_code == 401
    assert c.post('/api/auth/login', json={'email': 'james@example.com', 'password': 'newpassword'}).status_code == 401
    left = c.get('/api/sessions', headers=H(admin)).get_json()
    assert [f for s in left for f in s['files']] == ['dave.csv'], left
    assert c.get('/api/friends', headers=H(dave)).get_json()['friends'] == []

    # ---- the admin locked out: WAKEBACK_ADMIN_RESET sets the password at start-up
    os.environ['WAKEBACK_ADMIN_RESET'] = 'rescued-password'
    accounts.apply_admin_reset()
    assert c.post('/api/auth/login', json={'email': 'admin@example.com', 'password': 'rescued-password'}).status_code == 200
    print('server: all checks passed')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
