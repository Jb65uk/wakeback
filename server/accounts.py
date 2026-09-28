"""WakeBack accounts: users, sign-in, friends, sharing and the admin's tools.

Switched on by setting WAKEBACK_ADMIN=<your email> (the NAS). A dock Pi or the phone app runs
without it and behaves exactly as before: no logins, everything visible.

Storage: data/wakeback.db (SQLite) for users, sign-in tokens, friendships, settings and the audit
log. Who owns a track, and whether it's shared, stays in each session's owners.json
({"file": {"name", "email", "visibility": "friends"|"private"}}) so the phone app, the dock Pi
and the server all keep the same files.

API (all JSON):
  POST /api/auth/signup   {email, name, password}       -> {status: active|pending, token?}
  POST /api/auth/login    {email, password, cookie?}    -> {token, user}   (cookie: also set for the browser)
  POST /api/auth/logout
  GET  /api/auth/me                                     -> {accounts: true, user, friends, pending_in, pending_out}
  GET  /api/friends                                     -> {friends: [...], incoming: [...], outgoing: [...]}
  POST /api/friends/request {email}  · POST /api/friends/<id>/accept · /decline · DELETE /api/friends/<id>
  POST /api/sessions/<session>/tracks/<file>  {visibility}   (owner or admin; admin may also set owner_email)
  GET  /api/admin/users · POST /api/admin/users/<id> {status,name,role,password}
  GET/PUT /api/admin/settings {auto_approve}
  GET  /api/admin/audit
"""
import os, re, json, secrets, sqlite3, threading, time, hashlib
from contextlib import contextmanager
from functools import wraps
from flask import Blueprint, request, jsonify, g, abort, make_response
from werkzeug.security import generate_password_hash, check_password_hash

ADMIN_EMAIL = os.environ.get('WAKEBACK_ADMIN', '').strip().lower()
ENABLED = bool(ADMIN_EMAIL)
TOKEN_DAYS = 365
COOKIE = 'wb_token'
EMAIL_RE = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')

bp = Blueprint('accounts', __name__)
_db_lock = threading.Lock()
_db_path = None


def init(data_dir):
    """Create the database. Call once at start-up (also fine when accounts are off: nothing else runs)."""
    global _db_path
    _db_path = os.path.join(data_dir, 'wakeback.db')
    os.makedirs(data_dir, exist_ok=True)
    with connect() as c:
        c.executescript('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT NOT NULL, pw TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'user', status TEXT NOT NULL DEFAULT 'pending',
                created INTEGER NOT NULL, last_login INTEGER);
            CREATE TABLE IF NOT EXISTS tokens (
                hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created INTEGER NOT NULL, last_used INTEGER,
                device TEXT);
            CREATE TABLE IF NOT EXISTS friends (
                id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b INTEGER NOT NULL, requested_by INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending', created INTEGER NOT NULL, UNIQUE(a, b));
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS audit (
                id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, user_id INTEGER, who TEXT, action TEXT NOT NULL,
                target TEXT, details TEXT);
        ''')


@contextmanager
def connect():
    """A connection that commits each statement and is closed afterwards."""
    c = sqlite3.connect(_db_path, timeout=10, isolation_level=None)   # autocommit
    try:
        c.row_factory = sqlite3.Row
        c.execute('PRAGMA journal_mode=WAL')       # readers never block the one writer
        c.execute('PRAGMA busy_timeout=10000')
        yield c
    finally:
        c.close()


def setting(key, default=None):
    with connect() as c:
        r = c.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
    return json.loads(r['value']) if r else default


def set_setting(key, value):
    with connect() as c:
        c.execute('INSERT OR REPLACE INTO settings VALUES (?,?)', (key, json.dumps(value)))


def audit(action, target='', details=None, user=None):
    u = user if user is not None else getattr(g, 'user', None)
    with connect() as c:
        c.execute('INSERT INTO audit (ts,user_id,who,action,target,details) VALUES (?,?,?,?,?,?)',
                  (int(time.time() * 1000), u['id'] if u else None, u['email'] if u else None, action, target,
                   json.dumps(details) if details is not None else None))


def public_user(u):
    return {'id': u['id'], 'email': u['email'], 'name': u['name'], 'role': u['role'], 'status': u['status']}


def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def user_from_request():
    """The signed-in user for this request (bearer token or cookie), or None."""
    auth = request.headers.get('Authorization', '')
    token = auth[7:].strip() if auth.lower().startswith('bearer ') else request.cookies.get(COOKIE, '')
    if not token: return None
    with connect() as c:
        r = c.execute('SELECT u.* FROM tokens t JOIN users u ON u.id=t.user_id WHERE t.hash=?', (_hash(token),)).fetchone()
        if not r: return None
        c.execute('UPDATE tokens SET last_used=? WHERE hash=?', (int(time.time() * 1000), _hash(token)))
    return dict(r) if r['status'] == 'active' else None


def current_user():
    if not hasattr(g, 'user'): g.user = user_from_request() if ENABLED else None
    return g.user


def require_user(f):
    @wraps(f)
    def w(*a, **k):
        if ENABLED and not current_user(): return jsonify(error='Please sign in', login=True), 401
        return f(*a, **k)
    return w


def require_admin(f):
    @wraps(f)
    def w(*a, **k):
        if not ENABLED: return jsonify(error='Accounts are not switched on (set WAKEBACK_ADMIN)'), 404
        u = current_user()
        if not u: return jsonify(error='Please sign in', login=True), 401
        if u['role'] != 'admin': return jsonify(error='Admin only'), 403
        return f(*a, **k)
    return w


def is_admin():
    u = current_user()
    return bool(u and u['role'] == 'admin')


def friend_emails(user):
    """Emails of everyone this user is friends with (accepted)."""
    if not user: return set()
    with connect() as c:
        rows = c.execute('''SELECT u.email FROM friends f JOIN users u ON u.id = CASE WHEN f.a=? THEN f.b ELSE f.a END
                            WHERE (f.a=? OR f.b=?) AND f.status='accepted' ''', (user['id'], user['id'], user['id'])).fetchall()
    return {r['email'] for r in rows}


def can_see(owner, user, friends):
    """May `user` see a track with this owners.json entry? (Accounts off: everything.)"""
    if not ENABLED: return True
    if not user: return False
    if user['role'] == 'admin': return True
    email = (owner or {}).get('email', '').lower() if isinstance(owner, dict) else ''
    if not email: return True                      # club/dock tracks with no owner: everyone's
    if email == user['email']: return True
    return (owner.get('visibility') or 'friends') != 'private' and email in friends


def can_edit(owner):
    """May the signed-in user delete/change this track?"""
    if not ENABLED: return True
    u = current_user()
    if not u: return False
    if u['role'] == 'admin': return True
    email = (owner or {}).get('email', '').lower() if isinstance(owner, dict) else ''
    return email == u['email'] or not email         # your own, or an unowned club track


def _make_token(user_id, device):
    token = secrets.token_urlsafe(32)
    with connect() as c:
        c.execute('INSERT INTO tokens VALUES (?,?,?,?,?)', (_hash(token), user_id, int(time.time() * 1000), None, (device or '')[:80]))
        c.execute('UPDATE users SET last_login=? WHERE id=?', (int(time.time() * 1000), user_id))
    return token


def _reply_with_token(user, token, want_cookie):
    resp = make_response(jsonify(token=token, user=public_user(user), status=user['status']))
    if want_cookie:
        resp.set_cookie(COOKIE, token, max_age=TOKEN_DAYS * 86400, httponly=True, samesite='Lax', secure=request.is_secure)
    return resp


# ---------------------------------------------------------------- brute-force brake
# Password guessing is slowed two ways: per address (whoever is hammering) and per email (whoever is being
# hammered). Failed attempts count; a success clears the email's count. In memory: gunicorn runs one worker.
_attempts = {}            # key -> [t_ms, ...] of failures in the window
_attempts_lock = threading.Lock()
RATE_WINDOW_S, RATE_PER_IP, RATE_PER_EMAIL = 600, 20, 8


def client_ip():
    return (request.headers.get('CF-Connecting-IP') or request.headers.get('X-Forwarded-For', '').split(',')[0].strip()
            or request.remote_addr or '?')


def _too_many(keys):
    """(True, seconds to wait) if any key is over its limit."""
    now = time.time()
    with _attempts_lock:
        for key, limit in keys:
            hits = [t for t in _attempts.get(key, []) if now - t < RATE_WINDOW_S]
            _attempts[key] = hits
            if len(hits) >= limit:
                return True, int(RATE_WINDOW_S - (now - hits[0])) + 1
        # tidy the odd stale key so this never grows without bound
        if len(_attempts) > 5000:
            for k in [k for k, v in _attempts.items() if not v or now - v[-1] > RATE_WINDOW_S]: _attempts.pop(k, None)
    return False, 0


def _failed(keys):
    now = time.time()
    with _attempts_lock:
        for key, _ in keys:
            _attempts.setdefault(key, []).append(now)


def _cleared(email):
    with _attempts_lock:
        _attempts.pop('e:' + email, None)


def _rate_keys(email):
    return [('ip:' + client_ip(), RATE_PER_IP), ('e:' + email, RATE_PER_EMAIL)]


def _check_password_limited(email, pw):
    """The user row if the password is right; a (json, status) reply otherwise — including 'slow down'."""
    keys = _rate_keys(email)
    over, wait = _too_many(keys)
    if over:
        audit('login_blocked', email, {'ip': client_ip()})
        return None, (jsonify(error=f'Too many tries. Wait {max(1, wait // 60)} minute{"s" if wait > 120 else ""} and try again'), 429)
    with connect() as c:
        r = c.execute('SELECT * FROM users WHERE email=?', (email,)).fetchone()
    if not r or not check_password_hash(r['pw'], pw):
        _failed(keys)
        time.sleep(0.5)
        return None, (jsonify(error='Wrong email or password'), 401)
    _cleared(email)
    return dict(r), None


# ---------------------------------------------------------------- sign up / in / out

@bp.post('/api/auth/signup')
def signup():
    b = request.get_json(silent=True) or {}
    email, name, pw = str(b.get('email', '')).strip().lower(), str(b.get('name', '')).strip()[:40], str(b.get('password', ''))
    if not EMAIL_RE.match(email): return jsonify(error='That doesn\'t look like an email address'), 400
    over, wait = _too_many([('signup:' + client_ip(), 5)])     # 5 sign-ups per address per 10 minutes
    if over: return jsonify(error='Too many sign-ups from here. Try again later'), 429
    _failed([('signup:' + client_ip(), 5)])
    if not name: return jsonify(error='What should we call you?'), 400
    if len(pw) < 8: return jsonify(error='Password needs at least 8 characters'), 400
    with connect() as c:
        if c.execute('SELECT 1 FROM users WHERE email=?', (email,)).fetchone():
            return jsonify(error='There\'s already an account for that email. Log in instead.'), 409
        first = c.execute('SELECT COUNT(*) n FROM users').fetchone()['n'] == 0
        admin = email == ADMIN_EMAIL or (first and not ADMIN_EMAIL)
        status = 'active' if admin or setting('auto_approve', False) else 'pending'
        cur = c.execute('INSERT INTO users (email,name,pw,role,status,created) VALUES (?,?,?,?,?,?)',
                        (email, name, generate_password_hash(pw), 'admin' if admin else 'user', status, int(time.time() * 1000)))
        user = dict(c.execute('SELECT * FROM users WHERE id=?', (cur.lastrowid,)).fetchone())
    audit('signup', email, {'status': status}, user=user)
    if status != 'active':
        return jsonify(status='pending', user=public_user(user),
                       message='Account requested. You can log in once it\'s been approved.'), 202
    return _reply_with_token(user, _make_token(user['id'], b.get('device')), bool(b.get('cookie')))


@bp.post('/api/auth/login')
def login():
    b = request.get_json(silent=True) or {}
    email, pw = str(b.get('email', '')).strip().lower(), str(b.get('password', ''))
    user, bad = _check_password_limited(email, pw)
    if bad: return bad
    if user['status'] == 'pending': return jsonify(error='Your account hasn\'t been approved yet', status='pending'), 403
    if user['status'] == 'disabled': return jsonify(error='This account has been disabled', status='disabled'), 403
    audit('login', email, {'device': (b.get('device') or '')[:80]}, user=user)
    return _reply_with_token(user, _make_token(user['id'], b.get('device')), bool(b.get('cookie')))


@bp.post('/api/auth/logout')
def logout():
    auth = request.headers.get('Authorization', '')
    token = auth[7:].strip() if auth.lower().startswith('bearer ') else request.cookies.get(COOKIE, '')
    if token:
        with connect() as c: c.execute('DELETE FROM tokens WHERE hash=?', (_hash(token),))
    resp = make_response(jsonify(ok=True))
    resp.delete_cookie(COOKIE)
    return resp


@bp.get('/api/auth/me')
def me():
    if not ENABLED: return jsonify(accounts=False)
    u = current_user()
    if not u:
        # a pending user can ask how they're doing (email + password again)
        return jsonify(accounts=True, user=None, login=True), 401
    with connect() as c:
        n_in = c.execute("SELECT COUNT(*) n FROM friends WHERE status='pending' AND requested_by!=? AND (a=? OR b=?)", (u['id'], u['id'], u['id'])).fetchone()['n']
        n_out = c.execute("SELECT COUNT(*) n FROM friends WHERE status='pending' AND requested_by=?", (u['id'],)).fetchone()['n']
    return jsonify(accounts=True, user=public_user(u), friends=sorted(friend_emails(u)), pending_in=n_in, pending_out=n_out,
                   auto_approve=setting('auto_approve', False) if u['role'] == 'admin' else None)


@bp.post('/api/auth/status')
def status():
    """For the app's 'waiting for approval' screen: is this login active yet?"""
    b = request.get_json(silent=True) or {}
    user, bad = _check_password_limited(str(b.get('email', '')).strip().lower(), str(b.get('password', '')))
    if bad: return bad
    if user['status'] != 'active': return jsonify(status=user['status'])
    return _reply_with_token(user, _make_token(user['id'], b.get('device')), bool(b.get('cookie')))


@bp.post('/api/auth/password')
@require_user
def change_password():
    b = request.get_json(silent=True) or {}
    u = current_user()
    with connect() as c:
        r = c.execute('SELECT pw FROM users WHERE id=?', (u['id'],)).fetchone()
        if not check_password_hash(r['pw'], str(b.get('old', ''))): return jsonify(error='Current password is wrong'), 400
        if len(str(b.get('new', ''))) < 8: return jsonify(error='Password needs at least 8 characters'), 400
        c.execute('UPDATE users SET pw=? WHERE id=?', (generate_password_hash(str(b['new'])), u['id']))
    audit('password_changed', u['email'])
    return jsonify(ok=True)


# ---------------------------------------------------------------- friends

def _friend_row(r, me_id):
    other = {'id': r['oid'], 'name': r['oname'], 'email': r['oemail']}
    return {'id': r['id'], 'status': r['status'], 'requested_by_me': r['requested_by'] == me_id, 'user': other, 'created': r['created']}


def _friends_of(me_id):
    with connect() as c:
        rows = c.execute('''SELECT f.*, u.id oid, u.name oname, u.email oemail FROM friends f
                            JOIN users u ON u.id = CASE WHEN f.a=? THEN f.b ELSE f.a END
                            WHERE f.a=? OR f.b=? ORDER BY u.name COLLATE NOCASE''', (me_id, me_id, me_id)).fetchall()
    out = {'friends': [], 'incoming': [], 'outgoing': []}
    for r in rows:
        fr = _friend_row(r, me_id)
        out['friends' if r['status'] == 'accepted' else ('outgoing' if r['requested_by'] == me_id else 'incoming')].append(fr)
    return out


@bp.get('/api/friends')
@require_user
def friends():
    return jsonify(_friends_of(current_user()['id']))


@bp.post('/api/friends/request')
@require_user
def friend_request():
    me_ = current_user()
    email = str((request.get_json(silent=True) or {}).get('email', '')).strip().lower()
    if email == me_['email']: return jsonify(error='That\'s you'), 400
    with connect() as c:
        other = c.execute("SELECT * FROM users WHERE email=? AND status='active'", (email,)).fetchone()
        if not other: return jsonify(error='No WakeBack account with that email yet. Ask them to create one in the app first.'), 404
        a, b = sorted((me_['id'], other['id']))
        ex = c.execute('SELECT * FROM friends WHERE a=? AND b=?', (a, b)).fetchone()
        if ex:
            if ex['status'] == 'accepted': return jsonify(error=f"You're already friends with {other['name']}"), 409
            if ex['requested_by'] != me_['id']:   # they asked first: this counts as accepting
                c.execute("UPDATE friends SET status='accepted' WHERE id=?", (ex['id'],))
                accepted = True
            else:
                return jsonify(ok=True, status='pending', name=other['name'], message='Already asked; waiting for them')
        else:
            accepted = False
            c.execute('INSERT INTO friends (a,b,requested_by,status,created) VALUES (?,?,?,?,?)', (a, b, me_['id'], 'pending', int(time.time() * 1000)))
    audit('friend_accept' if accepted else 'friend_request', other['email'])
    return jsonify(ok=True, status='accepted' if accepted else 'pending', name=other['name'])


@bp.post('/api/friends/<int:fid>/<action>')
@require_user
def friend_action(fid, action):
    me_ = current_user()
    if action not in ('accept', 'decline'): abort(404)
    with connect() as c:
        r = c.execute('SELECT * FROM friends WHERE id=? AND (a=? OR b=?)', (fid, me_['id'], me_['id'])).fetchone()
        if not r: abort(404)
        if action == 'accept':
            if r['requested_by'] == me_['id']: return jsonify(error='Waiting for them to accept'), 400
            c.execute("UPDATE friends SET status='accepted' WHERE id=?", (fid,))
        else:
            c.execute('DELETE FROM friends WHERE id=?', (fid,))
    audit('friend_' + action, str(fid))
    return jsonify(ok=True)


@bp.delete('/api/friends/<int:fid>')
@require_user
def unfriend(fid):
    me_ = current_user()
    with connect() as c:
        n = c.execute('DELETE FROM friends WHERE id=? AND (a=? OR b=?)', (fid, me_['id'], me_['id'])).rowcount
    if not n: abort(404)
    audit('unfriend', str(fid))
    return jsonify(ok=True)


# ---------------------------------------------------------------- admin

@bp.get('/api/admin/users')
@require_admin
def admin_users():
    with connect() as c:
        rows = c.execute('SELECT * FROM users ORDER BY status DESC, name COLLATE NOCASE').fetchall()
        friends_n = {r['id']: r['n'] for r in c.execute("SELECT u.id, COUNT(f.id) n FROM users u LEFT JOIN friends f ON f.status='accepted' AND (f.a=u.id OR f.b=u.id) GROUP BY u.id")}
    return jsonify(users=[{**public_user(r), 'created': r['created'], 'last_login': r['last_login'], 'friends': friends_n.get(r['id'], 0)} for r in rows],
                   auto_approve=setting('auto_approve', False), admin_email=ADMIN_EMAIL)


@bp.post('/api/admin/users/<int:uid>')
@require_admin
def admin_user(uid):
    b = request.get_json(silent=True) or {}
    me_ = current_user()
    with connect() as c:
        r = c.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone()
        if not r: abort(404)
        changes = {}
        if b.get('status') in ('active', 'pending', 'disabled'):
            if uid == me_['id'] and b['status'] != 'active': return jsonify(error='You can\'t lock yourself out'), 400
            c.execute('UPDATE users SET status=? WHERE id=?', (b['status'], uid)); changes['status'] = b['status']
            if b['status'] == 'disabled': c.execute('DELETE FROM tokens WHERE user_id=?', (uid,))
        if b.get('role') in ('admin', 'user'):
            if uid == me_['id'] and b['role'] != 'admin': return jsonify(error='You can\'t demote yourself'), 400
            c.execute('UPDATE users SET role=? WHERE id=?', (b['role'], uid)); changes['role'] = b['role']
        if str(b.get('name', '')).strip():
            c.execute('UPDATE users SET name=? WHERE id=?', (str(b['name']).strip()[:40], uid)); changes['name'] = str(b['name']).strip()[:40]
        if b.get('password'):
            if len(str(b['password'])) < 8: return jsonify(error='Password needs at least 8 characters'), 400
            c.execute('UPDATE users SET pw=? WHERE id=?', (generate_password_hash(str(b['password'])), uid))
            c.execute('DELETE FROM tokens WHERE user_id=?', (uid,)); changes['password'] = 'reset'
        if b.get('sign_out'):
            c.execute('DELETE FROM tokens WHERE user_id=?', (uid,)); changes['sign_out'] = True
        user = dict(c.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone())
    audit('admin_user', user['email'], changes)
    return jsonify(public_user(user))


@bp.delete('/api/admin/users/<int:uid>')
@require_admin
def admin_delete_user(uid):
    if uid == current_user()['id']: return jsonify(error='You can\'t delete yourself'), 400
    with connect() as c:
        r = c.execute('SELECT email FROM users WHERE id=?', (uid,)).fetchone()
        if not r: abort(404)
        c.execute('DELETE FROM tokens WHERE user_id=?', (uid,))
        c.execute('DELETE FROM friends WHERE a=? OR b=?', (uid, uid))
        c.execute('DELETE FROM users WHERE id=?', (uid,))
    audit('admin_delete_user', r['email'])
    return jsonify(ok=True)


@bp.get('/api/admin/settings')
@require_admin
def admin_settings():
    return jsonify(auto_approve=setting('auto_approve', False))


@bp.put('/api/admin/settings')
@require_admin
def admin_put_settings():
    b = request.get_json(silent=True) or {}
    if 'auto_approve' in b:
        set_setting('auto_approve', bool(b['auto_approve']))
        audit('setting', 'auto_approve', bool(b['auto_approve']))
    return jsonify(auto_approve=setting('auto_approve', False))


@bp.get('/api/admin/audit')
@require_admin
def admin_audit():
    with connect() as c:
        rows = c.execute('SELECT * FROM audit ORDER BY id DESC LIMIT 300').fetchall()
    return jsonify([{**dict(r), 'details': json.loads(r['details']) if r['details'] else None} for r in rows])


def users_by_email():
    with connect() as c:
        return {r['email']: public_user(r) for r in c.execute('SELECT * FROM users')}
