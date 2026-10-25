#!/usr/bin/env python3
"""Checks the server's account routes end to end, on a throwaway copy:  python tools/test_server.py
Covers: tiny tracks left out of stats, stats by boat, league by class, forgot password, puck keys, who may read and change
a session, moving sessions, venues, the admin deleting a user, export, delete account."""
import io, json, math, os, shutil, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp(prefix='wakeback_test_')
shutil.copytree(os.path.join(ROOT, 'server'), os.path.join(tmp, 'server'))
shutil.copytree(os.path.join(ROOT, 'viewer'), os.path.join(tmp, 'viewer'))
os.environ['WAKEBACK_ADMIN'] = 'admin@example.com'
os.environ.pop('WAKEBACK_ADMIN_RESET', None)
sys.path.insert(0, os.path.join(tmp, 'server'))
import app as wb, accounts        # noqa: E402



@wb.app.get('/api/_boom')
def _boom():
    raise RuntimeError('on purpose')   # a bug in a route: the app must still get JSON back


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


def upload(tok, name, data, boat='', **form):
    r = c.post('/api/upload', headers=H(tok), data={'file': (io.BytesIO(data), name), 'boat': boat, **form}, content_type='multipart/form-data')
    assert r.status_code == 200, r.get_json()
    return r.get_json()


def owners_json(day):
    try:
        with open(os.path.join(tmp, 'data', 'sessions', day, 'owners.json')) as f: return json.load(f)
    except FileNotFoundError: return {}


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

    # ---- puck keys: a puck with Dave's key checks in and uploads as Dave, no sign-in needed
    assert c.post('/api/pucks/checkin', json={'puck': 7, 'battery_mv': 4000}).status_code == 200, 'check-ins never need a key (club pucks)'
    assert c.post('/api/upload', data={'file': (io.BytesIO(track(25)), 'puck7_x.csv')}, content_type='multipart/form-data').status_code == 401, 'uploads do'
    r = c.post('/api/pucks/keys', headers=H(dave), json={'puck': 7, 'label': 'Blue puck'})
    assert r.status_code == 200 and r.get_json()['key'] and r.get_json()['puck'] == 7, r.get_json()
    key7 = r.get_json()['key']
    assert c.post('/api/pucks/checkin', json={'puck': 7, 'fw': '1.2.0'}, headers={'X-Puck-Key': key7}).status_code == 200
    r = c.post('/api/upload', headers={'X-Puck-Key': key7}, data={'file': (io.BytesIO(track(25, t0=T0 + 86400_000)), 'puck7_sail.csv')}, content_type='multipart/form-data')
    assert r.status_code == 200, r.get_json()
    pk = [p for p in c.get('/api/pucks', headers=H(admin)).get_json()['pucks'] if p['puck'] == 7][0]
    assert pk['owner'] == 'Dave' and pk['fw'] == '1.2.0', pk
    mine = c.get('/api/pucks/keys', headers=H(dave)).get_json()['pucks']
    assert [(p['puck'], p['label'], p['fw']) for p in mine] == [(7, 'Blue puck', '1.2.0')] and mine[0]['last_seen'], mine
    assert 'key' not in mine[0], 'the key is only ever shown once'
    assert c.get('/api/pucks/keys', headers=H(james)).get_json()['pucks'] == [], 'not James\'s puck'
    owners7 = [s['owners'].get('puck7_sail.csv') for s in c.get('/api/sessions', headers=H(james)).get_json() if 'puck7_sail.csv' in s['files']]
    assert owners7 == ['Dave'], owners7
    # setting the same puck up again issues a new key and the old one stops working
    key7b = c.post('/api/pucks/keys', headers=H(dave), json={'puck': 7}).get_json()['key']
    assert c.post('/api/upload', headers={'X-Puck-Key': key7}, data={'file': (io.BytesIO(track(25)), 'puck7_old.csv')}, content_type='multipart/form-data').status_code == 401
    assert len(c.get('/api/pucks/keys', headers=H(dave)).get_json()['pucks']) == 1
    # the admin sees every key, with the owner, and can revoke one
    ap = c.get('/api/admin/pucks', headers=H(admin)).get_json()['pucks']
    assert len(ap) == 2 and ap[0]['owner']['email'] == 'dave@example.com' and ap[0]['revoked'] is None and ap[1]['revoked'], ap
    assert c.get('/api/admin/pucks', headers=H(dave)).status_code == 403
    assert c.delete(f'/api/admin/pucks/{ap[0]["id"]}', headers=H(admin)).status_code == 200
    assert c.post('/api/pucks/checkin', json={'puck': 7}, headers={'X-Puck-Key': key7b}).status_code == 200, 'a check-in with a dead key is still just a check-in'
    assert c.post('/api/upload', headers={'X-Puck-Key': key7b}, data={'file': (io.BytesIO(track(25)), 'puck7_x.csv')}, content_type='multipart/form-data').status_code == 401
    assert c.get('/api/pucks/keys', headers=H(dave)).get_json()['pucks'] == []
    assert [p['owner'] for p in c.get('/api/pucks', headers=H(admin)).get_json()['pucks'] if p['puck'] == 7] == [None], 'no live key: nobody\'s puck'
    c.post('/api/pucks/keys', headers=H(dave), json={'puck': 8})
    assert 8 in json.loads(zipfile.ZipFile(io.BytesIO(c.get('/api/me/export', headers=H(dave)).data)).read('account.json'))['pucks']
    # Dave's puck track doesn't muddle James's checks below
    assert c.delete(f'/api/sessions/{r.get_json()["session"]}/puck7_sail.csv', headers=H(dave)).status_code == 200

    # ---- a bug in a route still answers in JSON
    r = c.get('/api/_boom', headers=H(admin))
    assert r.status_code == 500 and r.get_json() == {'error': 'Something went wrong on the server'}, r.data

    # ---- only tracks are served or removed: the sidecars and made-up names are 404, never created
    day = [s for s in c.get('/api/sessions', headers=H(james)).get_json() if 'solo_am.csv' in s['files']][0]['id']
    assert c.get(f'/api/sessions/{day}/owners.json', headers=H(james)).status_code == 404
    assert c.delete(f'/api/sessions/{day}/crew.json', headers=H(admin)).status_code == 404
    assert c.get('/api/sessions/2030-01-01_nowhere/meta', headers=H(admin)).status_code == 404
    assert c.put('/api/sessions/2030-01-01_nowhere/crew', headers=H(admin), json={'puck1': 'Bob'}).status_code == 404
    assert not os.path.exists(os.path.join(tmp, 'data', 'sessions', '2030-01-01_nowhere')), 'no folder made for a made-up session'

    # ---- a session's names, races and course: only for people who can see a track in it; changes only from an owner
    eve = signup('eve@example.com', 'Eve')          # nobody's friend
    assert c.get(f'/api/sessions/{day}/crew', headers=H(eve)).status_code == 404
    assert c.put(f'/api/sessions/{day}/crew', headers=H(eve), json={'puck1': 'Eve'}).status_code == 404
    assert c.get(f'/api/sessions/{day}/crew', headers=H(dave)).status_code == 200, 'a friend with a track there'
    assert c.put(f'/api/sessions/{day}/crew', headers=H(dave), json={'solo_am.csv': 'James'}).status_code == 200
    assert c.get('/api/sailors', headers=H(eve)).get_json() == [], 'no names from sessions Eve can\'t see'
    assert 'James' in c.get('/api/sailors', headers=H(dave)).get_json()
    # moving a session needs every owner's say-so (or the admin): Dave shares this day with James
    assert c.post(f'/api/sessions/{day}/move', headers=H(dave), json={'venue': 'unknown'}).status_code == 403
    assert c.post(f'/api/sessions/{day}/move', headers=H(eve), json={'venue': 'unknown'}).status_code in (403, 404)
    # the admin lists owners' emails per track; nobody else does
    adm = [s for s in c.get('/api/sessions', headers=H(admin)).get_json() if s['id'] == day][0]
    assert adm['owner_emails']['solo_am.csv'] == 'james@example.com' and adm['owner_emails']['dave.csv'] == 'dave@example.com', adm
    assert 'owner_emails' not in [s for s in c.get('/api/sessions', headers=H(james)).get_json() if s['id'] == day][0]

    # ---- venues: anyone names an automatic one; a named venue is the admin's to change
    assert c.put('/api/venues/southport-sc', headers=H(james), json={'name': 'Not Southport'}).status_code == 403
    assert c.put('/api/venues/southport-sc', headers=H(admin), json={'name': 'Southport SC (Marine Lake)'}).status_code == 200
    r = c.post('/api/venues', headers=H(james), json={'id': 'near-5340n-00310w', 'name': 'New venue near 53.40, -3.10', 'lat': 53.40, 'lon': -3.10, 'auto': True})
    assert r.status_code == 201, r.get_json()
    assert c.put('/api/venues/near-5340n-00310w', headers=H(james), json={'name': 'West Kirby SC'}).status_code == 200
    assert c.put('/api/venues/near-5340n-00310w', headers=H(james), json={'name': 'West Kirby'}).status_code == 403, 'named now: admin only'

    # ---- moving a session: owners and names follow the files, renamed ones included; the puck list follows too
    r1 = upload(james, 'puck4_away.csv', track(25, 4.0, t0=T0 + 2 * 86400_000), boat='Solo 5843')
    r = c.post(f"/api/sessions/{r1['session']}/move", headers=H(james), json={'venue': 'near-5340n-00310w'})
    assert r.status_code == 200 and r.get_json()['session'].endswith('_near-5340n-00310w'), r.get_json()
    moved = r.get_json()['session']
    assert owners_json(moved)['puck4_away.csv']['email'] == 'james@example.com'
    r2 = upload(james, 'puck4_away.csv', track(25, 4.0, t0=T0 + 2 * 86400_000 + 3600_000))
    assert r2['session'] != moved
    assert c.post(f"/api/sessions/{r2['session']}/move", headers=H(james), json={'venue': 'near-5340n-00310w'}).get_json()['session'] == moved
    o = owners_json(moved)
    assert set(o) == {'puck4_away.csv', 'puck4_away-2.csv'} and o['puck4_away-2.csv']['name'] == 'James', o
    p4 = [p for p in c.get('/api/pucks', headers=H(james)).get_json()['pucks'] if p['puck'] == 4][0]
    assert p4['last_upload']['session'] == moved and p4['last_upload']['file'] == 'puck4_away-2.csv', p4
    for f in ('puck4_away.csv', 'puck4_away-2.csv'): assert c.delete(f'/api/sessions/{moved}/{f}', headers=H(james)).status_code == 200

    # ---- a puck key only speaks for the puck it was issued to
    key8 = c.post('/api/pucks/keys', headers=H(dave), json={'puck': 8}).get_json()['key']
    r = c.post('/api/upload', headers={'X-Puck-Key': key8}, data={'file': (io.BytesIO(track(25, t0=T0 + 3 * 86400_000)), 'puck5_x.csv')}, content_type='multipart/form-data')
    assert r.status_code == 200 and 'puck5_x.csv' not in owners_json(r.get_json()['session']), 'not Dave\'s track: the key is for puck 8'
    assert c.post('/api/pucks/checkin', json={'puck': 5}, headers={'X-Puck-Key': key8}).status_code == 200
    assert [p['owner'] for p in c.get('/api/pucks', headers=H(admin)).get_json()['pucks'] if p['puck'] == 5] == [None]
    assert c.delete(f"/api/sessions/{r.get_json()['session']}/puck5_x.csv", headers=H(admin)).status_code == 200

    # ---- the puck list only shows uploads you could open
    r = upload(dave, 'puck9_secret.csv', track(25, t0=T0 + 4 * 86400_000), visibility='private')
    p9 = lambda tok: [p['last_upload'] for p in c.get('/api/pucks', headers=H(tok)).get_json()['pucks'] if p['puck'] == 9]
    assert p9(dave)[0]['file'] == 'puck9_secret.csv' and p9(admin)[0]['file'] == 'puck9_secret.csv'
    assert p9(james) == [None], 'private: not for James'
    assert c.delete(f"/api/sessions/{r['session']}/puck9_secret.csv", headers=H(dave)).status_code == 200

    # ---- WiFi settings: the admin's, once accounts are on; this box can't change WiFi anyway
    assert c.get('/api/wifi/scan', headers=H(james)).status_code == 403
    assert c.get('/api/wifi/scan', headers=H(admin)).get_json()['available'] is False
    st = c.get('/api/dock/status', headers=H(james)).get_json()
    assert st['can_manage_wifi'] is False and 'nas' not in st and 'pin_required' not in st, st

    # ---- the admin deletes a user: the account goes, the tracks stay as club tracks owned by name
    tom = signup('tom@example.com', 'Tom')
    rt = upload(tom, 'tom.csv', track(25, t0=T0 + 5 * 86400_000))
    tid = [u['id'] for u in c.get('/api/admin/users', headers=H(admin)).get_json()['users'] if u['email'] == 'tom@example.com'][0]
    assert c.delete(f'/api/admin/users/{tid}', headers=H(eve)).status_code == 403
    r = c.delete(f'/api/admin/users/{tid}', headers=H(admin))
    assert r.status_code == 200 and r.get_json()['tracks_kept'] == 1, r.get_json()
    assert owners_json(rt['session'])['tom.csv'] == {'name': 'Tom', 'visibility': 'friends'}
    s_tom = [s for s in c.get('/api/sessions', headers=H(eve)).get_json() if s['id'] == rt['session']]
    assert s_tom and s_tom[0]['owners']['tom.csv'] == 'Tom' and 'tom.csv' in s_tom[0]['mine'], 'a club track now: everyone sees it'
    assert c.get('/api/stats', headers=H(tom)).status_code == 401
    assert c.delete(f"/api/sessions/{rt['session']}/tom.csv", headers=H(admin)).status_code == 200

    # ---- with accounts off, the account-only routes don't exist
    accounts.ENABLED = False
    try:
        assert c.post('/api/auth/signup', json={'email': 'x@example.com', 'name': 'X', 'password': 'password1'}).status_code == 404
        assert c.get('/api/friends').status_code == 404 and c.get('/api/pucks/keys').status_code == 404
        assert c.post('/api/auth/forgot', json={'email': 'x@example.com'}).status_code == 404
        assert c.get('/api/sessions').status_code == 200, 'everything else works without a sign-in'
    finally:
        accounts.ENABLED = True

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
