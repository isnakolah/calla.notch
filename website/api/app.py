"""Calla's first-party interest capture and private campaign reporting."""
import argparse
from collections import defaultdict, deque
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from functools import wraps
import csv
import getpass
import io
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import sys
import threading
import time
from urllib.parse import urlparse
from uuid import UUID

from flask import Flask, jsonify, request, send_from_directory, session
from werkzeug.security import check_password_hash, generate_password_hash

ROOT = Path(__file__).resolve().parents[1]
INTERESTS = {'live-calls', 'company-memory', 'team-pilot'}
EVENTS = {'pageview', 'engaged', 'demo_start', 'demo_25', 'demo_50', 'demo_75', 'demo_complete', 'chapter', 'cta_open', 'demo_interact'}
LOCAL = re.compile(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$")
DOMAIN_LABEL = re.compile(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')
CAMPAIGN_KEYS = ('utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term')


def valid_email(value):
    if not isinstance(value, str) or len(value) > 254 or value.count('@') != 1:
        return False
    local, domain = value.split('@')
    labels = domain.split('.')
    return (0 < len(local) <= 64 and bool(LOCAL.fullmatch(local)) and not local.startswith('.')
            and not local.endswith('.') and '..' not in local and len(labels) >= 2
            and all(DOMAIN_LABEL.fullmatch(label) for label in labels)
            and len(labels[-1]) >= 2 and labels[-1].isalpha())


def utcnow():
    return datetime.now(timezone.utc).isoformat()


def identifier(value):
    try:
        return str(UUID(value)) if isinstance(value, str) else ''
    except (ValueError, AttributeError):
        return ''


def campaign_values(value):
    if not isinstance(value, dict):
        return {}
    # Campaign labels only: never persist query strings, click IDs or full URLs.
    return {key: re.sub(r'[^a-zA-Z0-9 _.,+\-]', '', str(value.get(key, '')))[:100]
            for key in CAMPAIGN_KEYS}


@contextmanager
def connection(path, **kwargs):
    db = sqlite3.connect(path, **kwargs)
    db.row_factory = sqlite3.Row
    try:
        with db:
            yield db
    finally:
        db.close()


def create_app(database=None):
    app = Flask(__name__, static_folder=None)
    app.config.update(MAX_CONTENT_LENGTH=2048, SESSION_COOKIE_NAME='calla_dashboard', SESSION_COOKIE_HTTPONLY=True,
                      SESSION_COOKIE_SAMESITE='Strict', SESSION_COOKIE_SECURE=os.getenv('CALLA_SECURE_COOKIES') == '1',
                      PERMANENT_SESSION_LIFETIME=timedelta(hours=8))
    db_path = Path(database or os.getenv('CALLA_WAITLIST_DB', ROOT / '.data/waitlist.sqlite3'))
    app.config['DB'] = db_path
    db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    secrets_path = db_path.parent / 'admin.json'
    if not secrets_path.exists():
        try:
            with open(secrets_path, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as f:
                json.dump({'session_secret': secrets.token_hex(32), 'password_hash': ''}, f)
        except FileExistsError:
            pass
    private_config = json.loads(secrets_path.read_text())
    app.secret_key = os.getenv('CALLA_SESSION_SECRET') or private_config['session_secret']
    app.config['ADMIN_HASH'] = os.getenv('CALLA_ADMIN_PASSWORD_HASH') or private_config.get('password_hash', '')
    with connection(db_path) as db:
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE IF NOT EXISTS waitlist (email TEXT PRIMARY KEY, joined_at TEXT NOT NULL, consent TEXT NOT NULL)')
        existing = {r['name'] for r in db.execute('PRAGMA table_info(waitlist)')}
        for name, default in [('interests', "'[]'"), ('campaign', "'{}'"), ('session_id', "''"), ('updated_at', "''")]:
            if name not in existing:
                db.execute(f'ALTER TABLE waitlist ADD COLUMN {name} TEXT NOT NULL DEFAULT {default}')
        db.execute('''CREATE TABLE IF NOT EXISTS visits (
            id TEXT PRIMARY KEY, started_at TEXT NOT NULL, last_at TEXT NOT NULL,
            campaign TEXT NOT NULL, referrer TEXT NOT NULL, device TEXT NOT NULL)''')
        db.execute('''CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, name TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '', at TEXT NOT NULL)''')
        db.execute('CREATE INDEX IF NOT EXISTS events_visit ON events(session_id, name, detail)')
        db.execute('CREATE INDEX IF NOT EXISTS visits_date ON visits(started_at)')
        db.execute('CREATE INDEX IF NOT EXISTS events_date ON events(at)')
        db.execute('PRAGMA user_version=2')
    db_path.chmod(0o600)
    attempts = defaultdict(deque)
    mutex = threading.Lock()

    def limited(bucket, maximum, window=3600):
        ip = request.headers.get('X-Real-IP', request.remote_addr) if os.getenv('CALLA_TRUST_PROXY') == '1' else request.remote_addr
        now = time.monotonic()
        with mutex:
            for key in list(attempts):
                if not attempts[key] or now - attempts[key][-1] > 3600:
                    del attempts[key]
            recent = attempts[(bucket, ip)]
            while recent and now - recent[0] > window:
                recent.popleft()
            if len(recent) >= maximum or len(attempts) > 5000:
                return True
            recent.append(now)
        return False

    def same_origin():
        allowed = set(os.getenv('CALLA_ALLOWED_ORIGINS', 'http://127.0.0.1:4187,http://localhost:4187').split(','))
        origin = request.headers.get('Origin')
        return (not origin or origin in allowed) and request.headers.get('Sec-Fetch-Site') != 'cross-site'

    def payload():
        if not same_origin():
            return None, (jsonify(error='Please use the Calla page.'), 403)
        if not request.is_json:
            return None, (jsonify(error='Please use the form.'), 415)
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            return None, (jsonify(error='Invalid request.'), 400)
        return data, None

    def admin_required(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            if not session.get('admin'):
                return jsonify(error='Sign in to continue.'), 401
            return fn(*args, **kwargs)
        return wrapped

    @app.after_request
    def headers(response):
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
        response.headers['X-Frame-Options'] = 'DENY'
        response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        if request.path.startswith(('/api/', '/admin')):
            response.headers['Cache-Control'] = 'no-store'
        return response

    @app.errorhandler(413)
    def oversized(_):
        return jsonify(error='That request is too large.'), 413

    @app.get('/healthz')
    def health():
        try:
            with connection(db_path) as db:
                db.execute('SELECT 1 FROM waitlist LIMIT 1')
        except sqlite3.Error:
            return jsonify(ok=False), 503
        return jsonify(ok=True)

    @app.post('/api/waitlist')
    def waitlist():
        data, error = payload()
        if error:
            return error
        if data.get('website'):
            return jsonify(ok=True)
        email = data.get('email')
        email = email.strip().lower() if isinstance(email, str) else ''
        interests = data.get('interests', [])
        if not valid_email(email):
            return jsonify(error='Please enter a valid email address.'), 400
        if data.get('consent') != 'launch-notification-v1':
            return jsonify(error='Please use the launch-notification form.'), 400
        if not isinstance(interests, list) or any(not isinstance(x, str) or x not in INTERESTS for x in interests) or len(interests) > 3:
            return jsonify(error='Please choose one of the listed interests.'), 400
        if limited('signup', 20):
            return jsonify(error='Too many attempts. Please try again later.'), 429
        visit_id = identifier(data.get('session_id'))
        try:
            with connection(db_path, timeout=10) as db:
                db.execute('BEGIN IMMEDIATE')
                old = db.execute('SELECT interests FROM waitlist WHERE email=?', (email,)).fetchone()
                if old:
                    merged = sorted(set(json.loads(old['interests'])) | set(interests))
                    db.execute('UPDATE waitlist SET interests=?, updated_at=? WHERE email=?', (json.dumps(merged), utcnow(), email))
                else:
                    # Attribute only to a recorded visit. Do not invent conversions.
                    visit = db.execute('SELECT campaign FROM visits WHERE id=?', (visit_id,)).fetchone()
                    campaign = json.loads(visit['campaign']) if visit else campaign_values(data.get('campaign'))
                    db.execute('''INSERT INTO waitlist
                        (email,joined_at,consent,interests,campaign,session_id,updated_at) VALUES (?,?,?,?,?,?,?)''',
                        (email, utcnow(), 'launch-notification-v1', json.dumps(sorted(set(interests))), json.dumps(campaign), visit_id if visit else '', utcnow()))
        except sqlite3.Error:
            app.logger.error('Waitlist write failed')
            return jsonify(error='We couldn’t save your email. Please try again in a moment.'), 503
        # Identical response for new and existing addresses.
        return jsonify(ok=True)

    @app.post('/api/events')
    def collect():
        data, error = payload()
        if error:
            return error
        if re.search(r'bot|spider|crawler|headless|preview|facebookexternalhit', request.user_agent.string, re.I):
            return '', 204
        if request.headers.get('DNT') == '1' or request.headers.get('Sec-GPC') == '1':
            return '', 204
        event_id, visit_id = identifier(data.get('id')), identifier(data.get('session_id'))
        name = data.get('name')
        detail = data.get('detail', '')
        if not event_id or not visit_id or not isinstance(name, str) or name not in EVENTS:
            return jsonify(error='Invalid event.'), 400
        if name == 'chapter':
            if detail not in ['meeting', 'connected', 'company']:
                return jsonify(error='Invalid chapter.'), 400
        elif detail != '':
            return jsonify(error='Invalid event detail.'), 400
        if limited('events', 240, 60):
            return '', 429
        campaign = json.dumps(campaign_values(data.get('campaign')))
        ref = data.get('referrer', '')
        try:
            ref = urlparse(ref).hostname or '' if isinstance(ref, str) else ''
        except ValueError:
            ref = ''
        ref = ref[:150]
        device = data.get('device') if data.get('device') in ['desktop', 'tablet', 'mobile'] else 'desktop'
        try:
            with connection(db_path, timeout=10) as db:
                now = utcnow()
                db.execute('INSERT OR IGNORE INTO visits VALUES (?,?,?,?,?,?)', (visit_id, now, now, campaign, ref, device))
                db.execute('UPDATE visits SET last_at=? WHERE id=?', (now, visit_id))
                count = db.execute('SELECT COUNT(*) AS n FROM events WHERE session_id=?', (visit_id,)).fetchone()['n']
                # Milestones are unique per visit. Pageviews have a fresh event ID on each navigation.
                previous = db.execute('SELECT 1 FROM events WHERE session_id=? AND name=? AND detail=?', (visit_id, name, detail)).fetchone()
                if count < 100 and (name == 'pageview' or not previous):
                    db.execute('INSERT OR IGNORE INTO events VALUES (?,?,?,?,?)', (event_id, visit_id, name, detail, now))
        except sqlite3.Error:
            return '', 503
        return '', 204

    def local_setup():
        return (not app.config['ADMIN_HASH'] and os.getenv('CALLA_TRUST_PROXY') != '1'
                and request.remote_addr in ['127.0.0.1', '::1'])

    @app.get('/api/admin/session')
    def admin_session():
        if 'csrf' not in session:
            session['csrf'] = secrets.token_hex(24)
        return jsonify(authenticated=bool(session.get('admin')), setup=local_setup(), csrf=session['csrf'])

    @app.post('/api/admin/login')
    def login():
        data, error = payload()
        if error:
            return error
        if not secrets.compare_digest(str(data.get('csrf', '')), session.get('csrf', 'missing')):
            return jsonify(error='Refresh this page and try again.'), 403
        if limited('login', 8, 900):
            return jsonify(error='Too many attempts. Try again in 15 minutes.'), 429
        password = data.get('password', '')
        if not isinstance(password, str) or len(password) > 256:
            return jsonify(error='Invalid password.'), 400
        if local_setup():
            if len(password) < 12:
                return jsonify(error='Use a password of at least 12 characters.'), 400
            private_config['password_hash'] = generate_password_hash(password)
            temporary = secrets_path.with_suffix('.tmp')
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as f:
                json.dump(private_config, f)
            temporary.replace(secrets_path)
            app.config['ADMIN_HASH'] = private_config['password_hash']
        elif not app.config['ADMIN_HASH'] or not check_password_hash(app.config['ADMIN_HASH'], password):
            return jsonify(error='That password didn’t match.'), 401
        session.clear()
        session['admin'] = True
        session['csrf'] = secrets.token_hex(24)
        session.permanent = True
        return jsonify(ok=True, csrf=session['csrf'])

    @app.post('/api/admin/logout')
    @admin_required
    def logout():
        data, error = payload()
        if error:
            return error
        if not secrets.compare_digest(str(data.get('csrf', '')), session.get('csrf', 'missing')):
            return jsonify(error='Refresh this page and try again.'), 403
        session.clear()
        return jsonify(ok=True)

    def period():
        end = datetime.now(timezone.utc).date()
        try:
            days = int(request.args.get('days', 30))
            if days not in [7, 30, 90]:
                raise ValueError
            start = end - timedelta(days=days - 1)
            if request.args.get('start'):
                start = datetime.strptime(request.args['start'], '%Y-%m-%d').date()
                end = datetime.strptime(request.args.get('end', end.isoformat()), '%Y-%m-%d').date()
            if start > end or (end - start).days > 365:
                raise ValueError
            return start, end
        except (ValueError, TypeError):
            return None, None

    def report(start, end):
        lower, upper = start.isoformat(), (end + timedelta(days=1)).isoformat()
        with connection(db_path) as db:
            visits = [dict(r) for r in db.execute('SELECT * FROM visits WHERE started_at>=? AND started_at<? ORDER BY started_at', (lower, upper))]
            events = [dict(r) for r in db.execute('SELECT * FROM events WHERE at>=? AND at<?', (lower, upper))]
            leads = [dict(r) for r in db.execute('SELECT * FROM waitlist WHERE joined_at>=? AND joined_at<? ORDER BY joined_at DESC', (lower, upper))]
            total_leads = db.execute('SELECT COUNT(*) AS n FROM waitlist').fetchone()['n']
        visit_ids = {v['id'] for v in visits}
        events = [e for e in events if e['session_id'] in visit_ids]
        counts = {name: len({e['session_id'] for e in events if e['name'] == name}) for name in EVENTS}
        converted_ids = {lead['session_id'] for lead in leads if lead['session_id'] in visit_ids}
        visits_by_id = {v['id']: v for v in visits}
        daily = {}
        day = start
        while day <= end:
            daily[day.isoformat()] = {'date': day.isoformat(), 'visits': 0, 'signups': 0}
            day += timedelta(days=1)
        campaigns = {}
        devices = {'desktop': 0, 'tablet': 0, 'mobile': 0}
        sources = {}
        for v in visits:
            daily[v['started_at'][:10]]['visits'] += 1
            devices[v['device']] += 1
            c = json.loads(v['campaign'])
            source = c.get('utm_source') or v['referrer'] or 'Direct'
            key = (source, c.get('utm_medium') or '—', c.get('utm_campaign') or 'Unspecified')
            row = campaigns.setdefault(key, {'source': key[0], 'medium': key[1], 'campaign': key[2], 'visits': 0, 'conversions': 0, 'signups': 0})
            row['visits'] += 1
            row['conversions'] += int(v['id'] in converted_ids)
            sources[source] = sources.get(source, 0) + 1
        interests = dict.fromkeys(sorted(INTERESTS), 0)
        for lead in leads:
            lead['interests'] = json.loads(lead['interests'])
            lead['campaign'] = json.loads(lead['campaign'])
            campaign = lead['campaign']
            visit = visits_by_id.get(lead['session_id'], {})
            source = campaign.get('utm_source') or visit.get('referrer') or 'Direct'
            key = (source, campaign.get('utm_medium') or '—', campaign.get('utm_campaign') or 'Unspecified')
            row = campaigns.setdefault(key, {'source': key[0], 'medium': key[1], 'campaign': key[2], 'visits': 0, 'conversions': 0, 'signups': 0})
            row['signups'] += 1
            daily[lead['joined_at'][:10]]['signups'] += 1
            for interest in lead['interests']:
                if interest in interests:
                    interests[interest] += 1
        return {'start': start.isoformat(), 'end': end.isoformat(), 'generated_at': utcnow(),
                'visits': len(visits), 'pageviews': sum(e['name'] == 'pageview' for e in events),
                'engaged': counts['engaged'], 'demo_interactions': counts['demo_interact'], 'demo_starts': counts['demo_start'], 'demo_completions': counts['demo_complete'],
                'signups': len(leads), 'all_time_signups': total_leads, 'converted_visits': len(converted_ids),
                'conversion_rate': round(100 * len(converted_ids) / len(visits), 1) if visits else None,
                'completion_rate': round(100 * counts['demo_complete'] / counts['demo_start'], 1) if counts['demo_start'] else None,
                'milestones': {key: counts[key] for key in ['demo_start', 'demo_25', 'demo_50', 'demo_75', 'demo_complete']},
                'chapters': {key: len({e['session_id'] for e in events if e['name'] == 'chapter' and e['detail'] == key}) for key in ['meeting', 'connected', 'company']},
                'cta_opens': counts['cta_open'], 'interests': interests, 'devices': devices,
                'daily': list(daily.values()), 'campaigns': sorted(campaigns.values(), key=lambda x: x['visits'], reverse=True),
                'sources': sources, 'leads': leads}

    @app.get('/api/admin/report')
    @admin_required
    def admin_report():
        start, end = period()
        if not start:
            return jsonify(error='Choose a valid date range of up to one year.'), 400
        try:
            return jsonify(report(start, end))
        except sqlite3.Error:
            return jsonify(error='Reporting is temporarily unavailable.'), 503

    @app.get('/api/admin/export.csv')
    @admin_required
    def export_csv():
        start, end = period()
        if not start:
            return jsonify(error='Invalid date range.'), 400
        rows = report(start, end)['leads']
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(['email', 'joined_at', 'interests', 'source', 'medium', 'campaign', 'consent'])
        for row in rows:
            cells = [row['email'], row['joined_at'], ', '.join(row['interests']), *[row['campaign'].get(k, '') for k in CAMPAIGN_KEYS[:3]], row['consent']]
            writer.writerow([("'" + cell if cell.startswith(('=', '+', '-', '@')) else cell) for cell in cells])
        return app.response_class(output.getvalue(), mimetype='text/csv', headers={'Content-Disposition': f'attachment; filename="calla-interests-{start}-{end}.csv"'})

    @app.get('/admin')
    @app.get('/admin/')
    def admin_page():
        return send_from_directory(ROOT / 'dist', 'admin.html')

    @app.get('/')
    def index():
        return send_from_directory(ROOT / 'dist', 'index.html')

    @app.get('/<path:path>')
    def assets(path):
        if path.startswith(('api/', '.', 'admin/')):
            return jsonify(error='Not found.'), 404
        return send_from_directory(ROOT / 'dist', path)

    return app


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['serve', 'export', 'admin'], nargs='?', default='serve')
    parser.add_argument('--port', type=int, default=4188)
    parser.add_argument('--password-stdin', action='store_true', help='read the new admin password from standard input')
    args = parser.parse_args()
    app = create_app()
    if args.command == 'serve':
        app.run(host='127.0.0.1', port=args.port, debug=False)
    elif args.command == 'admin':
        password = sys.stdin.readline().rstrip('\r\n') if args.password_stdin else getpass.getpass('New dashboard password (12+ characters): ')
        if len(password) < 12 or (not args.password_stdin and password != getpass.getpass('Confirm password: ')):
            raise SystemExit('Passwords must match and contain at least 12 characters.')
        path = app.config['DB'].parent / 'admin.json'
        config = json.loads(path.read_text())
        config['password_hash'] = generate_password_hash(password)
        config['session_secret'] = secrets.token_hex(32)
        path.write_text(json.dumps(config))
        path.chmod(0o600)
        print('Dashboard password saved. Restart the API to apply it.')
    else:
        writer = csv.writer(sys.stdout)
        writer.writerow(['email', 'joined_at', 'consent', 'interests', 'campaign'])
        with connection(app.config['DB']) as db:
            for row in db.execute('SELECT email,joined_at,consent,interests,campaign FROM waitlist ORDER BY joined_at'):
                writer.writerow([("'" + cell if cell.startswith(('=', '+', '-', '@')) else cell) for cell in row])
