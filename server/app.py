#!/usr/bin/env python3
"""WakeBack server.

Runs in Docker on the NAS (gunicorn), on a club dock Pi, or on your laptop for development. It:
  - serves the viewer at /, the dock page at /dock, the admin page at /admin, the phone recorder at /record
  - lists sessions (folders of track files) at /api/sessions
  - serves track files from data/sessions/<date>_<venue>/<file>
  - accepts uploads from pucks and browsers at POST /api/upload (multipart, field "file")
  - stores who sailed which puck, per session, at /api/sessions/<session>/crew
  - files each track under a session = sailing date + venue ("2026-09-20_southport-sc"), with the venue
    found from where the track starts (data/venues.json), and records its owner (whose puck/phone sent
    it) separately from the sailor (who was in the boat)

Run:  python server/app.py            (http://localhost:5000)
"""
import os, re, json, threading, time, shutil, socket, subprocess, uuid
from datetime import datetime, timezone
from functools import wraps
from flask import Flask, request, jsonify, send_from_directory, abort, g
from werkzeug.exceptions import HTTPException
import accounts, stats as trackstats
from accounts import require_user, current_user, can_see, can_edit, friend_emails, is_admin
from stats import read_json, write_json

# ---------- settings (environment) ----------
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, 'data')
SESSIONS = os.path.join(DATA, 'sessions')
VIEWER = os.path.join(ROOT, 'viewer')
PUCKS = os.path.join(DATA, 'pucks.json')
VENUES = os.path.join(DATA, 'venues.json')
FLEET = int(os.environ.get('WAKEBACK_FLEET', '0') or 0)          # how many pucks the club has, so ones never seen still get a row
WIFI_SSID = os.environ.get('WAKEBACK_WIFI', 'wakeback')          # the dock Pi's own WiFi that pucks join (shown on the Dock page)
DOCK_OWNER = os.environ.get('WAKEBACK_OWNER', '')                # owner for pucks with none set, e.g. "Southport SC"
UPLINK_IF = os.environ.get('WAKEBACK_UPLINK_IF', 'wlan1')        # USB WiFi dongle for the club/home network; onboard wlan0 runs the dock's own WiFi
HAVE_NMCLI = bool(shutil.which('nmcli'))                         # NetworkManager (the Pi): the Dock page can change WiFi
DEMO_WIFI = os.environ.get('WAKEBACK_DEMO_WIFI', '0') == '1'      # made-up networks so the WiFi screens can be tried in VS Code
DEBUG = os.environ.get('WAKEBACK_DEBUG', '0') == '1'             # Flask's debugger: dev only, never on a server people can reach
ONLINE_SECS = 180     # a docked puck checks in about once a minute; three missed = gone
BOOT = time.time()
lock = threading.Lock()   # one process (gunicorn --workers 1): this keeps the JSON sidecars consistent

app = Flask(__name__, static_folder=None)
accounts.init(DATA)
accounts.apply_admin_reset()
app.register_blueprint(accounts.bp)


@app.errorhandler(HTTPException)
def api_errors(e):
    """API errors as JSON ({"error": "..."}), like the phone app's dock; pages keep Flask's HTML."""
    if request.path.startswith('/api/'):
        return jsonify(error=e.description if e.description and not e.description.startswith('The ') else e.name), e.code
    return e


@app.errorhandler(Exception)
def api_crash(e):
    """A bug in an API route: the phone app expects JSON, not Flask's HTML error page. The traceback goes to the log."""
    if isinstance(e, HTTPException) or not request.path.startswith('/api/'): raise e
    app.logger.exception('Unhandled error in %s %s', request.method, request.path)
    return jsonify(error='Something went wrong on the server'), 500


# ---------- small helpers ----------
SAFE_RE = re.compile(r'^[A-Za-z0-9._ -]+$')
PUCK_RE = re.compile(r'puck[_ -]?(\d+)', re.I)
SESSION_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})(?:_([a-z0-9-]+))?$')
UNKNOWN_VENUE = 'unknown'


class _Safe:
    """Allowed day/file names. Also refuses "." and "..", so nothing outside data/sessions can be read or deleted."""
    def match(self, s): return SAFE_RE.match(s) if s not in ('.', '..') else None
SAFE = _Safe()


def is_track(name):
    """Only CSV and GPX files are tracks; the JSON sidecars next to them are never served or deleted as one."""
    return name.lower().endswith(('.csv', '.gpx'))


def puck_of(fname):
    """'puck3' from a file name like puck3_174500.csv or Puck 03.gpx, else None."""
    m = PUCK_RE.match(fname or '')
    return f'puck{int(m.group(1))}' if m else None


def valid_pos(lat, lon):
    return -90 <= lat <= 90 and -180 <= lon <= 180


def session_tracks(d):
    return sorted(f for f in os.listdir(d) if is_track(f))


def owners_of(day):
    """owners.json for a session as {file: {name, email?, visibility, boat?}}, anything odd dropped."""
    raw = read_json(os.path.join(SESSIONS, day, 'owners.json'), {})
    return {f: o for f, o in raw.items() if isinstance(o, dict)} if isinstance(raw, dict) else {}


def iter_sessions():
    """Every session folder, newest first: (day, folder, date, venue id)."""
    for day in sorted(os.listdir(SESSIONS), reverse=True):
        d = os.path.join(SESSIONS, day)
        m = SESSION_RE.match(day)
        if m and os.path.isdir(d): yield day, d, m.group(1), m.group(2) or UNKNOWN_VENUE


def session_dir(day):
    """The folder for a session; 400 for a bad name, 404 if there's no such session (never makes one)."""
    if not SAFE.match(day): abort(400)
    d = os.path.join(SESSIONS, day)
    if not os.path.isdir(d): abort(404)
    return d


def session_access(day, edit=False):
    """The session's folder if this viewer may see a track in it (or change one, with edit); otherwise 404 (or
    403 when they can see it but not change it). The admin may do anything; without accounts, anyone may."""
    d = session_dir(day)
    if not accounts.ENABLED or is_admin(): return d
    owners = owners_of(day); user = current_user(); friends = friend_emails(user)
    files = session_tracks(d)
    if not any(can_see(owners.get(f), user, friends) for f in files): abort(404)
    if edit and not any(can_edit(owners.get(f)) for f in files): abort(403, 'Only the owner of a track here (or the admin) can change this session')
    return d


def require_admin_if_accounts(f):
    """Dock settings (WiFi): anyone on a club Pi without accounts; the admin only once accounts are on."""
    @wraps(f)
    def w(*a, **k):
        if accounts.ENABLED and not is_admin():
            if not current_user(): return jsonify(error='Please sign in', login=True), 401
            return jsonify(error='Admin only'), 403
        return f(*a, **k)
    return w


def first_timestamp(path):
    """Read the first timestamp in a CSV (t_ms) or GPX (<time>) so a session is filed by sailing date, not upload date."""
    try:
        with open(path, 'r', errors='ignore') as f:
            head = f.read(4000)
        if path.lower().endswith('.gpx'):
            m = re.search(r'<time>([^<]+)</time>', head)
            return datetime.fromisoformat(m.group(1).replace('Z', '+00:00')) if m else None
        lines = head.splitlines()
        if len(lines) < 2: return None
        cols = [c.strip().lower() for c in lines[0].split(',')]
        ti = next((i for i, c in enumerate(cols) if c.startswith('t')), 0)
        v = float(lines[1].split(',')[ti])
        if v > 1e12: v /= 1000
        return datetime.fromtimestamp(v, tz=timezone.utc)
    except Exception:
        return None


def first_fix(path):
    """(lat, lon) of the first position in a CSV or GPX, to work out the venue."""
    try:
        with open(path, 'r', errors='ignore') as f:
            head = f.read(6000)
        if path.lower().endswith('.gpx'):
            m = re.search(r'<trkpt\b([^>]*)>', head)
            la = re.search(r'\blat="([-0-9.]+)"', m.group(1)) if m else None
            lo = re.search(r'\blon="([-0-9.]+)"', m.group(1)) if m else None
            return (float(la.group(1)), float(lo.group(1))) if la and lo else None
        lines = head.splitlines()
        cols = [c.strip().lower() for c in lines[0].split(',')]
        la, lo = cols.index('lat'), cols.index('lon')
        for ln in lines[1:]:
            c = ln.split(',')
            try:
                lat, lon = float(c[la]), float(c[lo])
            except (ValueError, IndexError):
                continue
            if valid_pos(lat, lon) and (lat, lon) != (0.0, 0.0): return lat, lon
    except Exception:
        pass
    return None


# ---------- venues ----------
# Where people sail. A track is filed under the nearest venue within its radius; somewhere new gets an
# automatic venue ("New venue near 53.65, -3.01") that you name once.
DEFAULT_VENUES = [{'id': 'southport-sc', 'name': 'Southport SC (Marine Lake)', 'lat': 53.6503, 'lon': -3.0102, 'radius_m': 1500, 'auto': False}]


def load_venues():
    vs = read_json(VENUES, None)
    return vs if isinstance(vs, list) else [dict(v) for v in DEFAULT_VENUES]


def save_venues(vs):
    write_json(VENUES, vs)


def load_pucks():
    m = read_json(PUCKS, {})
    return m if isinstance(m, dict) else {}


def save_pucks(m):
    write_json(PUCKS, m)


def slug(name):
    return re.sub(r'-+', '-', re.sub(r'[^a-z0-9]+', '-', name.lower())).strip('-')[:30] or 'venue'


def auto_venue_id(lat, lon):
    return 'near-%s%s-%s%s' % (('%.2f' % abs(lat)).replace('.', ''), 'n' if lat >= 0 else 's', ('%.2f' % abs(lon)).replace('.', ''), 'e' if lon >= 0 else 'w')


def venue_for(pos):
    """Venue id for a position, adding an automatic venue if it's somewhere new. Call with `lock` held."""
    if not pos: return UNKNOWN_VENUE
    vs = load_venues()
    best = min(((trackstats._hav_m(pos[0], pos[1], v['lat'], v['lon']), v) for v in vs if 'lat' in v and 'lon' in v), default=None, key=lambda x: x[0])
    if best and best[0] <= best[1].get('radius_m', 1500): return best[1]['id']
    vid = auto_venue_id(*pos)
    if not any(v['id'] == vid for v in vs):
        vs.append({'id': vid, 'name': 'New venue near %.2f, %.2f' % pos, 'lat': round(pos[0], 4), 'lon': round(pos[1], 4), 'radius_m': 1500, 'auto': True})
        save_venues(vs)
    return vid


def venue_name(vid, vs=None):
    if vid == UNKNOWN_VENUE: return 'Unknown venue'
    return next((v['name'] for v in (vs or load_venues()) if v['id'] == vid), vid)


def venue_is_new(vid, vs):
    """Found automatically and not named yet (or no position at all)."""
    return vid == UNKNOWN_VENUE or any(v['id'] == vid and v.get('auto') for v in vs)


def migrate_date_folders():
    """Older docks filed sessions by date only ("2026-09-20"). Split each into date + venue folders."""
    moved = {}
    for day in sorted(os.listdir(SESSIONS)):
        src = os.path.join(SESSIONS, day)
        if not (os.path.isdir(src) and re.match(r'^\d{4}-\d{2}-\d{2}$', day)): continue
        groups = {}
        for f in session_tracks(src): groups.setdefault(venue_for(first_fix(os.path.join(src, f))), []).append(f)
        for vid, files in groups.items():
            dst = os.path.join(SESSIONS, f'{day}_{vid}'); os.makedirs(dst, exist_ok=True)
            for f in files:
                os.replace(os.path.join(src, f), os.path.join(dst, f)); moved[(day, f)] = f'{day}_{vid}'
            for j in ('races.json', 'meta.json', 'crew.json', 'owners.json'):   # the day's course and names go with every part
                if os.path.exists(os.path.join(src, j)) and not os.path.exists(os.path.join(dst, j)):
                    shutil.copyfile(os.path.join(src, j), os.path.join(dst, j))
        for f in os.listdir(src): os.remove(os.path.join(src, f))
        os.rmdir(src)
    if moved:
        m = load_pucks()
        for r in m.values():
            lu = r.get('last_upload')
            if lu and (lu.get('session'), lu.get('file')) in moved: lu['session'] = moved[(lu['session'], lu['file'])]
        save_pucks(m)
    return len(moved)


# ---------- pages ----------
@app.get('/')
def index():
    return send_from_directory(VIEWER, 'index.html')


@app.get('/viewer/<path:p>')
def viewer_static(p):
    return send_from_directory(VIEWER, p)


@app.get('/dock')
def dock_page():
    return send_from_directory(VIEWER, 'dock.html')


@app.get('/record')
def record_page():
    """Record a sail with the phone's own GPS in the browser, no app needed."""
    return send_from_directory(VIEWER, 'record.html')


@app.get('/admin')
def admin_page():
    if not accounts.ENABLED: return 'Accounts are off on this server (set WAKEBACK_ADMIN=<your email> to turn them on).', 404
    return send_from_directory(VIEWER, 'admin.html')


# ---------- sessions ----------
def visible_files(day, files, user, friends):
    """The tracks in a session folder this viewer may see, plus who owns them and how they're shared."""
    owners = owners_of(day)
    seen = [f for f in files if can_see(owners.get(f), user, friends)]
    me = (user or {}).get('email')
    share = {
        # names only: owners' emails stay on the server (the admin gets them, for the Tracks tab)
        'owners': {f: owners[f].get('name', '') for f in seen if f in owners},
        'sharing': {f: (owners[f].get('visibility') or 'friends') for f in seen if f in owners},
        'boats': {f: owners[f]['boat'] for f in seen if f in owners and owners[f].get('boat')},
        'mine': [f for f in seen if f not in owners or not owners[f].get('email') or owners[f].get('email', '').lower() == me] if accounts.ENABLED else seen,
    }
    if accounts.ENABLED and is_admin():
        share['owner_emails'] = {f: owners[f]['email'] for f in seen if f in owners and owners[f].get('email')}
    return seen, share


@app.get('/api/sessions')
@require_user
def sessions():
    out, vs = [], load_venues()
    user = current_user(); friends = friend_emails(user)
    for day, d, date, vid in iter_sessions():
        files, share = visible_files(day, session_tracks(d), user, friends)
        if not files: continue
        races = read_json(os.path.join(d, 'races.json'), [])
        out.append({'id': day, 'date': date, 'venue': vid, 'venue_name': venue_name(vid, vs), 'venue_new': venue_is_new(vid, vs),
                    'files': files, 'count': len(files), 'races': len(races) if isinstance(races, list) else 0, **share,
                    'stats': trackstats.session_stats(d, files)})
    out.sort(key=lambda s: (s['date'], s['venue_name']), reverse=True)
    return jsonify(out)


@app.get('/api/sessions/<day>/<name>')
@require_user
def track(day, name):
    if not SAFE.match(name): abort(400)
    d = session_dir(day)
    if not is_track(name) or not os.path.isfile(os.path.join(d, name)): abort(404)
    if not can_see(owners_of(day).get(name), current_user(), friend_emails(current_user())): abort(404)
    return send_from_directory(d, name)


@app.post('/api/upload')
@require_user
def upload():
    """Pucks and the browser both post here. Field: file. Optional: puck (e.g. 'puck3'), owner_name,
    owner_email, visibility, boat."""
    f = request.files.get('file')
    if not f or not f.filename: return jsonify(error='no file'), 400
    # phones name files all sorts of ways ("Morning sail (2).GPX"): tidy rather than refuse
    name = re.sub(r'[^A-Za-z0-9._ -]+', '_', os.path.basename(f.filename)).strip(' ._') or 'track.gpx'
    if not is_track(name):
        return jsonify(error='That file isn\'t a GPX or CSV track. In your sailing app, look for "Export GPX".'), 400
    puck = request.form.get('puck', '')
    owner_name = request.form.get('owner_name', '').strip()[:40]
    owner_email = request.form.get('owner_email', '').strip()[:120].lower()
    visibility = 'private' if request.form.get('visibility') == 'private' else 'friends'
    boat = request.form.get('boat', '').strip()[:40]   # which boat was sailed (Solo 5843, the Laser...)
    if puck and not name.lower().startswith(puck.lower()):
        name = f'{puck}_{name}'
    pk = puck_of(name)
    # a puck key signs the upload in as its owner, but only for the puck it was issued to
    key_row = getattr(g, 'puck_key', None)
    key_mismatch = bool(key_row and pk and key_row['puck'] != int(pk[4:]))
    if key_mismatch: app.logger.warning('Upload of %s with a key issued for puck%s: key ignored for ownership', name, key_row['puck'])
    if accounts.ENABLED:
        u, known = current_user(), accounts.users_by_email()
        if key_mismatch:
            owner_name, owner_email = '', ''
        # the track belongs to whoever's signed in, unless it's a friend's own puck (a known account)
        elif not (owner_email and owner_email in known and owner_email != u['email']):
            owner_name, owner_email = u['name'], u['email']
        else:
            owner_name = known[owner_email]['name']
    tmp = os.path.join(SESSIONS, f'.incoming_{uuid.uuid4().hex}{os.path.splitext(name)[1].lower()}')
    try:
        f.save(tmp)
        when = first_timestamp(tmp) or datetime.now(timezone.utc)
        with lock:
            vid = venue_for(first_fix(tmp))
            day = f"{when.strftime('%Y-%m-%d')}_{vid}"
            dest_dir = os.path.join(SESSIONS, day); os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, name)
            base, ext = os.path.splitext(name); n = 1
            while os.path.exists(dest):
                n += 1; dest = os.path.join(dest_dir, f'{base}-{n}{ext}')
            os.replace(tmp, dest)
            fname = os.path.basename(dest)
            if pk:
                m = load_pucks(); r = m.setdefault(pk, {})
                r['last_upload'] = {'time': int(time.time() * 1000), 'session': day, 'file': fname, 'bytes': os.path.getsize(dest)}
                save_pucks(m)
                if not owner_name and r.get('owner'): owner_name, owner_email = r['owner'].get('name', ''), r['owner'].get('email', '')
            if not owner_name and DOCK_OWNER: owner_name = DOCK_OWNER
            # owner: whose puck/phone sent it (can edit/delete it later). Sailor: who was in the boat (crew).
            if owner_name:
                op = os.path.join(dest_dir, 'owners.json'); owners = read_json(op, {})
                owners[fname] = {'name': owner_name, **({'email': owner_email} if owner_email else {}), 'visibility': visibility, **({'boat': boat} if boat else {})}
                write_json(op, owners)
                # the owner's own track: name the boat after them unless someone's said otherwise
                if owner_name != DOCK_OWNER:
                    cp = os.path.join(dest_dir, 'crew.json'); crew = read_json(cp, {})
                    if not crew.get(pk or fname): crew[pk or fname] = owner_name; write_json(cp, crew)
    finally:
        if os.path.exists(tmp): os.remove(tmp)
    if accounts.ENABLED: accounts.audit('upload', f'{day}/{fname}', {'owner': owner_email})
    return jsonify(ok=True, session=day, file=fname, venue=vid, venue_name=venue_name(vid))


@app.delete('/api/sessions/<day>/<name>')
@require_user
def delete_track(day, name):
    if not SAFE.match(name): abort(400)
    d = session_dir(day); p = os.path.join(d, name)
    if not is_track(name) or not os.path.isfile(p): abort(404)
    op = os.path.join(d, 'owners.json')
    with lock:
        owners = read_json(op, {})
        if not can_edit(owners.get(name)): return jsonify(error='Only the owner (or the admin) can remove this track'), 403
        os.remove(p)
        if name in owners: owners.pop(name); write_json(op, owners)
    if accounts.ENABLED: accounts.audit('delete_track', f'{day}/{name}')
    return jsonify(ok=True)


@app.post('/api/sessions/<day>/tracks/<name>')
@require_user
def track_settings(day, name):
    """Sharing (friends/private) and the boat — owner or admin. Admin may also hand a track to another user."""
    if not SAFE.match(name): abort(400)
    d = session_dir(day)
    if not is_track(name) or not os.path.isfile(os.path.join(d, name)): abort(404)
    b = request.get_json(silent=True) or {}
    op = os.path.join(d, 'owners.json')
    with lock:
        owners = read_json(op, {}); o = dict(owners.get(name) or {})
        if not can_edit(owners.get(name)): return jsonify(error='Only the owner (or the admin) can change this track'), 403
        changes = {}
        if b.get('visibility') in ('friends', 'private'): o['visibility'] = b['visibility']; changes['visibility'] = b['visibility']
        if 'boat' in b:
            boat = str(b.get('boat') or '').strip()[:40]
            if boat: o['boat'] = boat
            else: o.pop('boat', None)
            changes['boat'] = boat
        if 'owner_email' in b:
            if not is_admin(): return jsonify(error='Only the admin can change who owns a track'), 403
            email = str(b['owner_email'] or '').strip().lower()
            if email:
                known = accounts.users_by_email()
                if email not in known: return jsonify(error='No account with that email'), 400
                o['email'], o['name'] = email, known[email]['name']
            else:
                o.pop('email', None); o['name'] = str(b.get('owner_name') or o.get('name') or '')[:40]
            changes['owner'] = email or o.get('name')
        if not changes: return jsonify(error='nothing to change'), 400
        o.setdefault('visibility', 'friends'); o.setdefault('name', '')
        owners[name] = o; write_json(op, owners)
    if accounts.ENABLED: accounts.audit('track_settings', f'{day}/{name}', changes)
    return jsonify({'name': o.get('name', ''), 'visibility': o.get('visibility', 'friends'), 'boat': o.get('boat', ''), **({'email': o['email']} if is_admin() and o.get('email') else {})})


def disown_tracks(email):
    """An account was deleted by the admin: its tracks stay, as club tracks owned by name. Returns how many."""
    email = (email or '').lower(); n = 0
    with lock:
        for day, d, _, _ in iter_sessions():
            op = os.path.join(d, 'owners.json'); owners = read_json(op, {}); changed = False
            for o in (owners.values() if isinstance(owners, dict) else []):
                if isinstance(o, dict) and (o.get('email') or '').lower() == email:
                    o.pop('email'); changed = True; n += 1
            if changed: write_json(op, owners)
    return n
accounts.on_account_deleted = disown_tracks


def clean_marks(ms):
    """Course marks: name, position, and which side to leave them (port = red, stbd = green)."""
    out = []
    for m in (ms if isinstance(ms, list) else [])[:30]:
        try:
            lat, lon = float(m['lat']), float(m['lon'])
            if not valid_pos(lat, lon): continue
            out.append({'id': str(m.get('id', ''))[:16], 'name': str(m.get('name', 'Mark'))[:30], 'lat': lat, 'lon': lon,
                        'side': 'stbd' if m.get('side') == 'stbd' else 'port'})
        except (KeyError, TypeError, ValueError): pass
    return out


def clean_lines(ls):
    """Start/finish lines: kind, committee boat end (a) and pin end (b)."""
    out = []
    for l in (ls if isinstance(ls, list) else [])[:6]:
        try:
            ends = {}
            for w in ('a', 'b'):
                lat, lon = float(l[w]['lat']), float(l[w]['lon'])
                if not valid_pos(lat, lon): raise ValueError
                ends[w] = {'lat': lat, 'lon': lon}
            out.append({'id': str(l.get('id', ''))[:16], 'kind': l.get('kind') if l.get('kind') in ('start', 'finish', 'both') else 'start', **ends})
        except (KeyError, TypeError, ValueError): pass
    return out


def clean_weather(w):
    """Wind for the day from Open-Meteo: {src, lat, lon, got, pts: [[t_ms, dir, kn, gust|null], ...]}."""
    if not isinstance(w, dict): return None
    pts = []
    for p in (w.get('pts') if isinstance(w.get('pts'), list) else [])[:2000]:
        try:
            t, d, s = int(p[0]), float(p[1]) % 360, float(p[2])
            g_ = float(p[3]) if len(p) > 3 and p[3] is not None else None
            if 0 <= s <= 200 and (g_ is None or 0 <= g_ <= 250): pts.append([t, d, s, g_])
        except (TypeError, ValueError, IndexError, KeyError): pass
    if not pts: return None
    out = {'src': str(w.get('src', ''))[:40], 'pts': pts}
    try:
        lat, lon = float(w['lat']), float(w['lon'])
        if valid_pos(lat, lon): out['lat'], out['lon'] = lat, lon
    except (KeyError, TypeError, ValueError): pass
    try: out['got'] = int(w['got'])
    except (KeyError, TypeError, ValueError): pass
    return out


def clean_gun(v):
    try: return int(v) if v else None
    except (TypeError, ValueError): return None


# ---------- session meta: whole-session marks and your corrections to tacks/gybes/marks ----------
@app.get('/api/sessions/<day>/meta')
@require_user
def get_meta(day):
    d = session_access(day)
    got = read_json(os.path.join(d, 'meta.json'), {})
    return jsonify(got if isinstance(got, dict) else {})


@app.put('/api/sessions/<day>/meta')
@require_user
def put_meta(day):
    d = session_access(day, edit=True)
    body = request.get_json(silent=True)
    if not isinstance(body, dict): return jsonify(error='expected an object'), 400
    fixes = []
    for f in (body.get('fixes') if isinstance(body.get('fixes'), list) else [])[:2000]:
        try:
            if f['kind'] in ('Tack', 'Gybe', 'Mark', 'none'): fixes.append({'k': str(f['k'])[:80], 't': int(f['t']), 'kind': f['kind']})
        except (KeyError, TypeError, ValueError): pass
    clean = {'marks': clean_marks(body.get('marks')), 'fixes': fixes, 'lines': clean_lines(body.get('lines'))}
    gun = clean_gun(body.get('gun'))
    if gun: clean['gun'] = gun
    wx = clean_weather(body.get('weather'))
    if wx: clean['weather'] = wx
    with lock: write_json(os.path.join(d, 'meta.json'), clean)
    return jsonify(clean)


# ---------- races (time windows within a session day, each with its own marks) ----------
@app.get('/api/sessions/<day>/races')
@require_user
def get_races(day):
    d = session_access(day)
    got = read_json(os.path.join(d, 'races.json'), [])
    return jsonify(got if isinstance(got, list) else [])


@app.put('/api/sessions/<day>/races')
@require_user
def put_races(day):
    d = session_access(day, edit=True)
    body = request.get_json(silent=True)
    if not isinstance(body, list): return jsonify(error='expected a list'), 400
    clean = []
    for r in body:
        try:
            st, en = int(r['start']), int(r['end'])
            if en > st:
                race = {'name': str(r.get('name', 'Race'))[:40], 'start': st, 'end': en, 'marks': clean_marks(r.get('marks')), 'lines': clean_lines(r.get('lines'))}
                gun = clean_gun(r.get('gun'))
                if gun: race['gun'] = gun
                clean.append(race)
        except (KeyError, TypeError, ValueError): pass
    clean.sort(key=lambda r: r['start'])
    with lock: write_json(os.path.join(d, 'races.json'), clean)
    return jsonify(clean)


# ---------- crew: who had which puck, per session ----------
# Puck numbers never change; pucks get handed out differently each time, so names live with the session.
@app.get('/api/sessions/<day>/crew')
@require_user
def get_crew(day):
    d = session_access(day)
    got = read_json(os.path.join(d, 'crew.json'), {})
    return jsonify(got if isinstance(got, dict) else {})


@app.put('/api/sessions/<day>/crew')
@require_user
def put_crew(day):
    d = session_access(day, edit=True)
    body = request.get_json(silent=True)
    if not isinstance(body, dict): return jsonify(error='expected an object'), 400
    clean = {str(k)[:80]: str(v).strip()[:40] for k, v in body.items() if str(v).strip()}
    with lock: write_json(os.path.join(d, 'crew.json'), clean)
    return jsonify(clean)


# ---------- stats and the league ----------
def _rows_for(user, period, league=False):
    """Every visible track as a row with its owner, for stats and the league.
    For the league even the admin only sees what a friend would: private sails stay off the board."""
    since = trackstats.period_start(period)
    friends = friend_emails(user); vs = load_venues(); rows = []
    def on_board(o):
        if not (league and accounts.ENABLED and user and isinstance(o, dict)): return True
        email = (o.get('email') or '').lower()
        return not email or email == user['email'] or ((o.get('visibility') or 'friends') != 'private' and email in friends)
    for day, d, date, vid in iter_sessions():
        owners = owners_of(day)
        files = [f for f in session_tracks(d) if can_see(owners.get(f), user, friends) and on_board(owners.get(f))]
        if not files: continue
        st = trackstats.session_stats(d, files)
        for f in files:
            if f not in st or st[f]['start_ms'] < since: continue
            if not trackstats.counts(st[f]): continue         # too short to be a sail: not in stats or the league
            o = owners.get(f, {})
            rows.append({'session': day, 'date': date, 'venue': vid, 'venue_name': venue_name(vid, vs), 'file': f, 'stats': st[f],
                         'owner_email': (o.get('email') or '').lower(), 'owner_name': o.get('name') or '', 'boat': o.get('boat') or ''})
    return rows


def _names(values):
    """Distinct non-empty names, case-insensitively, first spelling kept, sorted."""
    seen = {}
    for v in values:
        if v and v.lower() not in seen: seen[v.lower()] = v
    return sorted(seen.values(), key=str.lower)


@app.get('/api/stats')
@require_user
def my_stats():
    """Your totals (or, without accounts, everything on this server): ?period=month|year|all"""
    user = current_user(); period = request.args.get('period', 'all')
    rows = _rows_for(user, period)
    if accounts.ENABLED and user:
        rows = [r for r in rows if r['owner_email'] == user['email'] or (not r['owner_email'] and r['owner_name'] == user['name'])]
    # ?boat=Solo 5843: just the sails in that boat. `boats` lists every boat you've sailed, for the picker.
    boats = _names(r['boat'] for r in rows)
    boat = request.args.get('boat', '').strip()
    if boat: rows = [r for r in rows if r['boat'].lower() == boat.lower()]
    return jsonify(period=period, boats=boats, boat=boat, **trackstats.summarise(rows))


@app.get('/api/league')
@require_user
def league():
    """You and your friends (and the club's unowned tracks), ranked: ?period=month|year|all"""
    user = current_user(); period = request.args.get('period', 'all')
    by = {}
    rows = _rows_for(user, period, league=True)
    # ?cls=Solo: only sails in that class of boat (the boat's name without its sail number)
    classes = _names(trackstats.boat_class(r['boat']) for r in rows)
    cls = request.args.get('cls', '').strip()
    if cls: rows = [r for r in rows if trackstats.boat_class(r['boat']).lower() == cls.lower()]
    for r in rows:
        key = r['owner_email'] or (r['owner_name'] or 'Club')
        by.setdefault(key, {'name': r['owner_name'] or 'Club', 'rows': []})['rows'].append(r)
    people = []
    for key, v in by.items():
        sm = trackstats.summarise(v['rows'])
        people.append({'name': v['name'], 'me': bool(user) and (key == user['email'] or (not '@' in key and key == user['name'])),
                       'sessions': sm['sessions'], 'dist_nm': sm['dist_nm'], 'moving_h': sm['moving_h'], 'max_kn': sm['max_kn'],
                       'avg_kn': sm['avg_kn'], 'best_avg_kn': sm['best_avg_kn'], 'longest_nm': sm.get('longest_nm', 0)})
    people.sort(key=lambda p: -p['dist_nm'])
    return jsonify(period=period, people=people, classes=classes, cls=cls)


# ---------- your data: take it with you, or take it away ----------
def _my_tracks(user):
    """(day, file, owner record) for every track this account owns."""
    out = []
    for day, d, _, _ in iter_sessions():
        owners = owners_of(day)
        for f in session_tracks(d):
            o = owners.get(f)
            if o and (o.get('email') or '').lower() == user['email']: out.append((day, f, o))
    return out


@app.get('/api/me/export')
@require_user
def export_me():
    """Everything held about you, as a zip: your account details, your friends' names, and your tracks."""
    if not accounts.ENABLED: abort(404)
    import io, zipfile
    from flask import send_file
    user = current_user(); vs = load_venues()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        listing = []
        for day, f, o in _my_tracks(user):
            m = SESSION_RE.match(day); vid = (m.group(2) if m else None) or UNKNOWN_VENUE
            z.write(os.path.join(SESSIONS, day, f), f'tracks/{day}/{f}')
            listing.append({'session': day, 'date': m.group(1) if m else day[:10], 'venue': venue_name(vid, vs), 'file': f,
                            'boat': o.get('boat') or '', 'sharing': o.get('visibility') or 'friends'})
        z.writestr('account.json', json.dumps({**accounts.export_account(user), 'tracks': listing}, indent=1))
        z.writestr('README.txt', 'Your WakeBack data.\n\naccount.json: your account details, friends and a list of your tracks.\n'
                                 'tracks/: every track you own, as recorded (CSV or GPX), by sailing day and venue.\n')
    accounts.audit('export', user['email'], {'tracks': len(listing)})
    buf.seek(0)
    return send_file(buf, mimetype='application/zip', as_attachment=True, download_name='wakeback-my-data.zip')


@app.delete('/api/me')
@require_user
def delete_me():
    """Delete your account and every track you own. Needs your password. Can't be undone."""
    if not accounts.ENABLED: abort(404)
    user = current_user()
    bad = accounts.check_can_delete(user, str((request.get_json(silent=True) or {}).get('password', '')))
    if bad: return bad
    n = 0
    with lock:
        for day, f, _ in _my_tracks(user):
            d = os.path.join(SESSIONS, day)
            try: os.remove(os.path.join(d, f))
            except OSError: continue
            n += 1
            op = os.path.join(d, 'owners.json'); owners = read_json(op, {})
            if f in owners: owners.pop(f); write_json(op, owners)
            # nobody else's track left in the session: the course, names and stats go with it
            if not session_tracks(d): shutil.rmtree(d, ignore_errors=True)
    accounts.delete_account(user)
    accounts.audit('account_deleted', user['email'], {'tracks': n}, user={'id': None, 'email': user['email']})
    resp = jsonify(ok=True, tracks=n)
    resp.delete_cookie(accounts.COOKIE)
    return resp


@app.get('/api/sailors')
@require_user
def sailors():
    """Every name used in a session you can see, for the name picker."""
    names = set()
    user = current_user(); friends = friend_emails(user)
    for day, d, _, _ in iter_sessions():
        if accounts.ENABLED and not is_admin():
            owners = owners_of(day)
            if not any(can_see(owners.get(f), user, friends) for f in session_tracks(d)): continue
        crew = read_json(os.path.join(d, 'crew.json'), {})
        if isinstance(crew, dict): names.update(str(v) for v in crew.values() if v)
    return jsonify(sorted(names, key=str.lower))


# ---------- venues ----------
@app.get('/api/venues')
@require_user
def venues():
    return jsonify(sorted(load_venues(), key=lambda v: v['name'].lower()))


def clean_venue(b, old=None):
    v = dict(old or {})
    if 'name' in b:
        n = str(b['name']).strip()[:60]
        if not n: abort(400, 'a venue needs a name')
        v['name'] = n; v['auto'] = False
    for k, lo, hi in (('lat', -90, 90), ('lon', -180, 180), ('radius_m', 100, 20000)):
        if k in b:
            try: x = float(b[k])
            except (TypeError, ValueError): abort(400, f'bad {k}')
            if not lo <= x <= hi: abort(400, f'{k} out of range')
            v[k] = round(x, 5) if k != 'radius_m' else int(x)
    return v


@app.post('/api/venues')
@require_user
def add_venue():
    b = request.get_json(silent=True)
    if not isinstance(b, dict) or not b.get('name') or 'lat' not in b or 'lon' not in b:
        return jsonify(error='name, lat and lon needed'), 400
    with lock:
        vs = load_venues()
        want = str(b.get('id') or '')
        if want and re.match(r'^[a-z0-9-]{1,40}$', want) and any(v['id'] == want for v in vs):
            return jsonify(next(v for v in vs if v['id'] == want))      # already here (sync sends it again)
        vid = want if re.match(r'^[a-z0-9-]{1,40}$', want) else slug(str(b['name']))
        base, n = vid, 1
        while any(v['id'] == vid for v in vs) or vid == UNKNOWN_VENUE: n += 1; vid = f'{base}-{n}'
        v = clean_venue(b, {'id': vid, 'radius_m': 1500}); v['auto'] = bool(b.get('auto', False))
        vs.append(v); save_venues(vs)
    return jsonify(v), 201


@app.put('/api/venues/<vid>')
@require_user
def put_venue(vid):
    """Name a venue found automatically (anyone), or change a named one (the admin, once accounts are on)."""
    b = request.get_json(silent=True)
    if not isinstance(b, dict): return jsonify(error='expected an object'), 400
    with lock:
        vs = load_venues()
        i = next((k for k, v in enumerate(vs) if v['id'] == vid), None)
        if i is None: abort(404)
        if accounts.ENABLED and not is_admin() and not vs[i].get('auto'):
            return jsonify(error='Only the admin can change a named venue'), 403
        vs[i] = clean_venue(b, vs[i]); save_venues(vs)
    return jsonify(vs[i])


@app.post('/api/sessions/<day>/move')
@require_user
def move_session(day):
    """Wrong venue? Move the whole session to another one (merging if that session exists)."""
    src = session_dir(day)
    b = request.get_json(silent=True) or {}
    vid = str(b.get('venue', ''))
    m = SESSION_RE.match(day)
    if not m: abort(404)
    if vid != UNKNOWN_VENUE and not any(v['id'] == vid for v in load_venues()): return jsonify(error='no such venue'), 400
    new = f'{m.group(1)}_{vid}'
    if new == day: return jsonify(session=day)
    with lock:
        owners = owners_of(day); tracks = session_tracks(src)
        # everyone's tracks move together, so everyone's (or the admin's) say-so is needed
        if not all(can_edit(owners.get(f)) for f in tracks): return jsonify(error='Only the owner of every track here (or the admin) can move this session'), 403
        dst = os.path.join(SESSIONS, new); os.makedirs(dst, exist_ok=True)
        dst_owners = read_json(os.path.join(dst, 'owners.json'), {}); src_crew = read_json(os.path.join(src, 'crew.json'), {})
        dst_crew = read_json(os.path.join(dst, 'crew.json'), {})
        renamed = {}
        for f in tracks:
            a, b2 = os.path.join(src, f), os.path.join(dst, f)
            base, ext = os.path.splitext(f); n = 1
            while os.path.exists(b2): n += 1; b2 = os.path.join(dst, f'{base}-{n}{ext}')
            os.replace(a, b2); renamed[f] = os.path.basename(b2)
            # a renamed file keeps its owner and sailor under the new name
            if f in owners: dst_owners[renamed[f]] = owners[f]
        for k, v in (src_crew.items() if isinstance(src_crew, dict) else []):
            if k in renamed: dst_crew[renamed[k]] = v
            else: dst_crew.setdefault(k, v)          # keyed by puck: the destination's name for that puck wins
        if dst_owners: write_json(os.path.join(dst, 'owners.json'), dst_owners)
        if dst_crew: write_json(os.path.join(dst, 'crew.json'), dst_crew)
        for f in os.listdir(src):
            a, b2 = os.path.join(src, f), os.path.join(dst, f)
            if f in ('crew.json', 'owners.json') or os.path.exists(b2): os.remove(a)
            else: os.replace(a, b2)
        os.rmdir(src)
        pm = load_pucks(); touched = False
        for r in pm.values():
            lu = r.get('last_upload')
            if lu and lu.get('session') == day:
                lu['session'] = new; lu['file'] = renamed.get(lu.get('file'), lu.get('file')); touched = True
        if touched: save_pucks(pm)
    return jsonify(session=new)


# ---------- dock: puck check-ins, status, internet ----------
# single-cell LiPo, resting voltage -> rough % (good enough for a dock screen)
LIPO = [(4.20, 100), (4.10, 90), (4.00, 78), (3.90, 62), (3.80, 45), (3.75, 35), (3.70, 22), (3.65, 12), (3.60, 6), (3.50, 2), (3.30, 0)]
def pct_from_mv(mv):
    v = mv / 1000
    if v >= LIPO[0][0]: return 100
    for (v1, p1), (v2, p2) in zip(LIPO, LIPO[1:]):
        if v >= v2: return round(p2 + (p1 - p2) * (v - v2) / (v1 - v2))
    return 0


@app.post('/api/pucks/checkin')
def puck_checkin():
    """Pucks call this every ~30 s while on the pad (and once on waking near the dock).
    JSON: {"puck": 3, "battery_mv": 4012, "charging": "charging"|"full"|"not", "on_pad": true,
           "free_kb": 12000, "total_kb": 14336, "fw": "0.3.1", "pending": 1, "rssi": -52}"""
    b = request.get_json(silent=True) or {}
    try: num = int(str(b.get('puck', '')).replace('puck', ''))
    except ValueError: return jsonify(error='puck number missing'), 400
    if not 1 <= num <= 99: return jsonify(error='puck number out of range'), 400
    now = int(time.time() * 1000)
    # a puck set up from the app sends its key: that says whose puck it is (stage 4)
    key = request.headers.get('X-Puck-Key', '')
    key_row = accounts.touch_puck_key(key, b.get('fw')) if accounts.ENABLED else None
    if key_row and key_row['puck'] != num:
        app.logger.warning('puck%s checked in with a key issued for puck%s: key ignored', num, key_row['puck'])
        key_row, key = None, ''                     # neither claims nor clears the owner
    owner = accounts.current_user() if key_row else None
    with lock:
        m = load_pucks(); r = m.setdefault(f'puck{num}', {})
        for k in ('battery_mv', 'free_kb', 'total_kb', 'pending', 'rssi'):
            if isinstance(b.get(k), (int, float)): r[k] = b[k]
        if b.get('charging') in ('charging', 'full', 'not'): r['charging'] = b['charging']
        if isinstance(b.get('fw'), str): r['fw'] = b['fw'][:16]
        for k in ('orientation', 'mag', 'gps_fix', 'twist'):
            if isinstance(b.get(k), (int, float, str)): r[k] = b[k]
        r['on_pad'] = bool(b.get('on_pad', True))
        r['last_seen'] = now
        if r['on_pad']: r['last_on_pad'] = now
        if owner: r['owner'] = {'name': owner['name'], 'email': owner['email']}
        elif key: r.pop('owner', None)       # its key was revoked: nobody's puck until it's set up again
        save_pucks(m)
    # the puck uses this reply to set its clock before GPS lock and to know the dock heard it
    return jsonify(ok=True, time_ms=now)


def last_sailor(session, fname):
    crew = read_json(os.path.join(SESSIONS, session, 'crew.json'), None)
    if not isinstance(crew, dict): return None
    return crew.get(puck_of(fname) or '') or crew.get(fname)


@app.get('/api/pucks')
@require_user
def pucks():
    now = time.time() * 1000
    m = load_pucks()
    # with accounts on, a sailor only learns about uploads they could open anyway
    restrict = accounts.ENABLED and not is_admin()
    user = current_user(); friends = friend_emails(user)
    if restrict:
        for r in m.values():
            lu = r.get('last_upload')
            if lu and not can_see(owners_of(lu.get('session', '')).get(lu.get('file')), user, friends): r['last_upload'] = None
    # fall back to the files on disk for last upload (works for sessions copied in by hand, and the demo data)
    for day, dd, _, _ in iter_sessions():
        owners = owners_of(day) if restrict else {}
        for fn in os.listdir(dd):
            pk = puck_of(fn)
            if not pk or not is_track(fn): continue
            if restrict and not can_see(owners.get(fn), user, friends): continue
            r = m.setdefault(pk, {})
            fp = os.path.join(dd, fn); mt = int(os.path.getmtime(fp) * 1000)
            lu = r.get('last_upload')
            if not lu or (lu.get('session', '') < day) or (lu.get('session') == day and lu.get('time', 0) < mt and not os.path.exists(os.path.join(SESSIONS, lu['session'], lu.get('file', '')))):
                r['last_upload'] = {'time': mt, 'session': day, 'file': fn, 'bytes': os.path.getsize(fp)}
    for n in range(1, FLEET + 1): m.setdefault(f'puck{n}', {})
    keyed = accounts.puck_owners() if accounts.ENABLED else {}      # pucks with a live key: whose they are
    out = []
    for key, r in sorted(m.items(), key=lambda kv: int(kv[0][4:])):
        num = int(key[4:])
        if num in keyed: r['owner'] = {'name': keyed[num]['name'], 'email': keyed[num]['email']}
        seen = r.get('last_seen')
        docked = bool(r.get('on_pad')) and seen is not None and now - seen < ONLINE_SECS * 1000
        lu = r.get('last_upload')
        out.append({
            'puck': num, 'docked': docked, 'last_seen': seen, 'last_on_pad': r.get('last_on_pad'),
            'battery_pct': pct_from_mv(r['battery_mv']) if 'battery_mv' in r else None, 'battery_mv': r.get('battery_mv'),
            'charging': r.get('charging') if docked else None,
            'free_kb': r.get('free_kb'), 'total_kb': r.get('total_kb'), 'fw': r.get('fw'), 'pending': r.get('pending'), 'rssi': r.get('rssi'),
            'orientation': r.get('orientation'), 'mag': r.get('mag'), 'gps_fix': r.get('gps_fix'), 'twist': r.get('twist'),
            'owner': (r.get('owner') or {}).get('name') or None,      # the owner's name only: emails stay on the server
            'last_upload': dict(lu, sailor=last_sailor(lu['session'], lu.get('file'))) if lu else None,
        })
    return jsonify(pucks=out, now=int(now))


def online():
    try:
        socket.create_connection(('1.1.1.1', 53), timeout=1.5).close(); return True
    except OSError:
        return False


def nmcli(*args, timeout=20):
    if not HAVE_NMCLI: return None
    try:
        return subprocess.run(['nmcli', *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


DEMO_NETS = [('SSC Members', 82, True), ('SSC Guest', 64, False), ('BT-Hub-4F2A', 41, True), ('Pier Free WiFi', 23, False)]
demo_state = {'connected': None}


@app.get('/api/dock/status')
@require_user
def dock_status():
    du = shutil.disk_usage(SESSIONS)
    nets = []
    r = nmcli('-t', '-f', 'DEVICE,TYPE,STATE,CONNECTION', 'device')
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            dev, typ, state, con = (line.split(':') + ['', '', '', ''])[:4]
            if typ in ('wifi', 'ethernet'): nets.append({'device': dev, 'type': typ, 'state': state, 'connection': con})
    if DEMO_WIFI and demo_state['connected']:
        nets.append({'device': UPLINK_IF, 'type': 'wifi', 'state': 'connected', 'connection': demo_state['connected']})
    return jsonify(
        online=online(), networks=nets, can_manage_wifi=HAVE_NMCLI or DEMO_WIFI, demo=DEMO_WIFI, dock_wifi=WIFI_SSID,
        hostname=socket.gethostname(), time_ms=int(time.time() * 1000), uptime_s=int(time.time() - BOOT),
        disk_free=du.free, disk_total=du.total,
        sessions=sum(1 for _ in iter_sessions()),
        accounts=accounts.ENABLED,
    )


@app.get('/api/wifi/scan')
@require_user
@require_admin_if_accounts
def wifi_scan():
    if DEMO_WIFI:
        time.sleep(1)   # feels like a scan
        return jsonify(available=True, demo=True, networks=[{'ssid': n, 'signal': sg, 'secure': sec, 'in_use': n == demo_state['connected']} for n, sg, sec in DEMO_NETS])
    if not HAVE_NMCLI: return jsonify(available=False, networks=[])
    nmcli('device', 'wifi', 'rescan', 'ifname', UPLINK_IF, timeout=15)
    r = nmcli('-t', '-f', 'IN-USE,SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list', 'ifname', UPLINK_IF)
    seen, nets = set(), []
    for line in (r.stdout.splitlines() if r and r.returncode == 0 else []):
        parts = re.split(r'(?<!\\):', line)
        if len(parts) < 4 or not parts[1] or parts[1] in seen or parts[1] == WIFI_SSID: continue
        seen.add(parts[1])
        nets.append({'ssid': parts[1].replace('\\:', ':'), 'signal': int(parts[2] or 0), 'secure': parts[3] not in ('', '--'), 'in_use': parts[0] == '*'})
    nets.sort(key=lambda n: -n['signal'])
    return jsonify(available=True, networks=nets)


@app.post('/api/wifi/connect')
@require_user
@require_admin_if_accounts
def wifi_connect():
    b = request.get_json(silent=True) or {}
    ssid, pw = str(b.get('ssid', ''))[:64], str(b.get('password', ''))[:128]
    if not ssid: return jsonify(error='Pick a network first.'), 400
    if DEMO_WIFI:
        secure = next((sec for n, _, sec in DEMO_NETS if n == ssid), True)
        time.sleep(1.5)
        if secure and not pw: return jsonify(error='That network needs a password.'), 400
        if secure and pw.lower() == 'wrong': return jsonify(error='The password was wrong.'), 400
        demo_state['connected'] = ssid
        return jsonify(ok=True, online=online(), demo=True)
    if not HAVE_NMCLI: return jsonify(error='This server can\'t change WiFi (no NetworkManager).'), 400
    args = ['device', 'wifi', 'connect', ssid, 'ifname', UPLINK_IF] + (['password', pw] if pw else [])
    r = nmcli(*args, timeout=45)
    if not r or r.returncode != 0:
        msg = (r.stderr or r.stdout).strip() if r else 'no reply from network manager'
        if 'Secrets were required' in msg or 'password' in msg.lower(): msg = 'The password was wrong.'
        return jsonify(error=f'Could not connect: {msg}'), 400
    return jsonify(ok=True, online=online())


# ---------- hello: pucks (and the app) check they've found a WakeBack server, and set their clock ----------
@app.get('/api/hello')
def hello():
    return jsonify(dock='wakeback', time_ms=int(datetime.now(timezone.utc).timestamp() * 1000))


os.makedirs(SESSIONS, exist_ok=True)
_n = migrate_date_folders()
if _n: print(f'Moved {_n} track(s) from date-only folders into date + venue sessions')

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    print(f'WakeBack on http://localhost:{port}  (sessions in {SESSIONS})')
    app.run(host='0.0.0.0', port=port, debug=DEBUG)   # dev; the container runs gunicorn
