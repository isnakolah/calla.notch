import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('waitlist_app', Path(__file__).with_name('app.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WaitlistTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Path(self.temp.name) / 'waitlist.sqlite3'
        self.app = module.create_app(self.db)
        self.app.testing = True
        self.client = self.app.test_client()

    def tearDown(self):
        self.temp.cleanup()

    def post(self, email='person@example.com', **extra):
        return self.client.post('/api/waitlist', json={'email': email, 'consent': 'launch-notification-v1', **extra}, headers={'Origin': 'http://127.0.0.1:4187'})

    def rows(self):
        with module.connection(self.db) as db:
            return db.execute('SELECT * FROM waitlist').fetchall()

    def test_signup_duplicate_and_restart(self):
        self.assertEqual(self.post(' Person@Example.com ').status_code, 200)
        self.assertEqual(self.post().status_code, 200)
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(self.rows()[0][0], 'person@example.com')
        restarted = module.create_app(self.db).test_client()
        self.assertEqual(restarted.get('/healthz').status_code, 200)
        self.assertEqual(len(self.rows()), 1)

    def test_invalid_email_and_consent(self):
        for email in ['invalid', 'x@', '<x@y.com>', 'a..b@example.com', '.a@example.com', 'a@-bad.com', 'a@b.c', 'a\n@b.com', None, ['a@b.com']]:
            with self.subTest(email=email):
                self.assertEqual(self.post(email).status_code, 400)
        self.assertEqual(self.post(consent='other').status_code, 400)
        self.assertEqual(self.rows(), [])

    def test_cross_origin_and_content_type(self):
        self.assertEqual(self.client.post('/api/waitlist', json={'email': 'x@y.com'}, headers={'Origin': 'https://other.example'}).status_code, 403)
        self.assertEqual(self.client.post('/api/waitlist', data='x@y.com').status_code, 415)
        self.assertEqual(self.client.post('/api/waitlist', data='[', content_type='application/json').status_code, 400)

    def test_honeypot_does_not_store(self):
        self.assertEqual(self.post(website='bot').status_code, 200)
        self.assertEqual(self.rows(), [])

    def test_limits_and_private_storage(self):
        for _ in range(20):
            self.assertEqual(self.post().status_code, 200)
        self.assertEqual(self.post().status_code, 429)
        self.assertEqual(self.client.post('/api/waitlist', data='x' * 3000, content_type='application/json').status_code, 413)
        for path in ['/api/waitlist', '/.data/waitlist.sqlite3', '/api/export', '/../api/app.py']:
            self.assertIn(self.client.get(path).status_code, [404, 405])

    def test_failed_storage_does_not_confirm_signup(self):
        with module.connection(self.db) as db:
            db.execute('DROP TABLE waitlist')
        response = self.post()
        self.assertEqual(response.status_code, 503)
        self.assertNotIn('ok', response.json)
        self.assertEqual(self.client.get('/healthz').status_code, 503)


if __name__ == '__main__':
    unittest.main()

class ReportingTests(unittest.TestCase):
    post = WaitlistTests.post
    rows = WaitlistTests.rows
    tearDown = WaitlistTests.tearDown
    def event(self, name='pageview', visit=None, event_id=None, **extra):
        from uuid import uuid4
        return self.client.post('/api/events', json={'id': event_id or str(uuid4()), 'session_id': visit or self.visit,
            'name': name, 'campaign': {'utm_source': 'linkedin', 'utm_medium': 'paid-social', 'utm_campaign': 'launch'}, **extra})

    def setUp(self):
        WaitlistTests.setUp(self)
        from uuid import uuid4
        self.visit = str(uuid4())

    def login(self):
        info = self.client.get('/api/admin/session').json
        result = self.client.post('/api/admin/login', json={'csrf': info['csrf'], 'password': 'local-test-password-2026'})
        self.assertEqual(result.status_code, 200)
        return result.json['csrf']

    def test_migration_retains_existing_addresses(self):
        old = Path(self.temp.name) / 'old.sqlite3'
        with module.connection(old) as db:
            db.execute('CREATE TABLE waitlist (email TEXT PRIMARY KEY,joined_at TEXT NOT NULL,consent TEXT NOT NULL)')
            db.execute('INSERT INTO waitlist VALUES (?,?,?)', ('legacy@example.com','2026-01-01T00:00:00+00:00','launch-notification-v1'))
        module.create_app(old)
        with module.connection(old) as db:
            row = db.execute('SELECT * FROM waitlist').fetchone()
            self.assertEqual(row['email'], 'legacy@example.com')
            self.assertEqual(row['interests'], '[]')
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 2)

    def test_events_deduplicate_and_signup_conversion_is_server_counted(self):
        from uuid import uuid4
        import json
        eid = str(uuid4())
        self.assertEqual(self.event(event_id=eid).status_code, 204)
        self.assertEqual(self.event(event_id=eid).status_code, 204)
        for _ in range(3):
            self.assertEqual(self.event('demo_start').status_code, 204)
        self.post(interests=['live-calls'], session_id=self.visit)
        self.post(interests=['company-memory'], session_id=self.visit)
        self.login()
        report = self.client.get('/api/admin/report').json
        self.assertEqual(report['visits'], 1)
        self.assertEqual(report['pageviews'], 1)
        self.assertEqual(report['demo_starts'], 1)
        self.assertEqual(report['signups'], 1)
        self.assertEqual(report['conversion_rate'], 100)
        self.assertEqual(report['campaigns'][0]['conversions'], 1)
        self.assertEqual(report['interests']['live-calls'], 1)
        self.assertEqual(report['interests']['company-memory'], 1)
        self.assertEqual(report['leads'][0]['campaign']['utm_source'], 'linkedin')

    def test_auth_csrf_logout_and_exports(self):
        for path in ['/api/admin/report','/api/admin/export.csv']:
            self.assertEqual(self.client.get(path).status_code, 401)
        self.assertEqual(self.client.post('/api/admin/login',json={'csrf':'bad','password':'long-test-password'}).status_code,403)
        csrf = self.login()
        self.assertEqual(self.client.get('/api/admin/report?start=2026-10-31&end=2026-10-01').status_code,400)
        self.assertEqual(self.client.get('/api/admin/report?days=4').status_code,400)
        self.post('=formula@example.com', interests=['team-pilot'])
        exported = self.client.get('/api/admin/export.csv')
        self.assertEqual(exported.status_code,200)
        self.assertIn("'=formula@example.com",exported.text)
        self.assertIn('no-store',exported.headers['Cache-Control'])
        self.assertEqual(self.client.post('/api/admin/logout',json={'csrf':'bad'}).status_code,403)
        self.assertEqual(self.client.post('/api/admin/logout',json={'csrf':csrf}).status_code,200)
        self.assertEqual(self.client.get('/api/admin/report').status_code,401)
        info = self.client.get('/api/admin/session').json
        self.assertFalse(info['setup'])
        self.assertEqual(self.client.post('/api/admin/login',json={'csrf':info['csrf'],'password':'wrong-password'}).status_code,401)

    def test_invalid_interests_events_and_privacy_signals(self):
        self.assertEqual(self.post(interests=['not-a-choice']).status_code,400)
        self.assertEqual(self.event('email', detail='person@example.com').status_code,400)
        self.assertEqual(self.event('chapter',detail='company').status_code,204)
        self.assertEqual(self.event('chapter',detail='arbitrary').status_code,400)
        self.assertEqual(self.event('pageview',detail={'email':'x@y.com'}).status_code,400)
        from uuid import uuid4
        for headers in [{'DNT':'1'},{'Sec-GPC':'1'},{'User-Agent':'Googlebot'}]:
            self.client.post('/api/events',json={'id':str(uuid4()),'session_id':str(uuid4()),'name':'pageview'},headers=headers)
        with module.connection(self.db) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM visits').fetchone()[0],1)

    def test_concurrent_duplicate_signups_stay_one_lead(self):
        from concurrent.futures import ThreadPoolExecutor
        def signup(_):
            return self.app.test_client().post('/api/waitlist',json={'email':'same@example.com','consent':'launch-notification-v1','interests':['live-calls']}).status_code
        with ThreadPoolExecutor(max_workers=6) as pool:
            self.assertEqual(list(pool.map(signup,range(6))),[200]*6)
        self.assertEqual(len(self.rows()),1)

    def test_untracked_signup_keeps_campaign_without_inventing_visits(self):
        self.post(interests=['company-memory'], campaign={'utm_source':'newsletter','utm_campaign':'launch'})
        self.login()
        report = self.client.get('/api/admin/report').json
        self.assertEqual(report['visits'], 0)
        self.assertEqual(report['signups'], 1)
        self.assertIsNone(report['conversion_rate'])
        self.assertIsNone(report['completion_rate'])
        self.assertEqual(report['campaigns'][0]['signups'], 1)
        self.assertEqual(report['campaigns'][0]['source'], 'newsletter')
        self.assertEqual(report['campaigns'][0]['conversions'], 0)
