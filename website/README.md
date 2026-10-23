# Calla: a shared brain for your team’s work

Help visitors understand the company-brain vision through one ordinary conversation.
The landing page gives a recognizable anatomical brain the main stage: fine neural
threads follow its wrinkles, a signal travels to a related piece of knowledge, and
the brain turns gently to reveal that connection. A smaller captioned call shows
how Calla’s actual Mac app supplies the context.

## Local review

```sh
cd website
./scripts/preview.sh
```

Open **http://127.0.0.1:4187/**. This is the production frontend build served with
the real API. It starts a silent, captioned sample automatically, loops the complete
45-second recording, and keeps playback, captions and
illustrative neuron connections on the same clock. Play/pause, seeking and replay
remain available. A browser that blocks autoplay can use the Play control.

Open **http://127.0.0.1:4187/admin** for the private dashboard. On the first local
visit, choose a password of at least 12 characters. There is no default password.
First-time browser setup is disabled behind the production proxy. Passwords are
hashed; the signing secret and hash live in `.data/admin.json` with mode 0600.
The deployment script creates the production password on its first run and saves
it locally at `~/.config/calla/landing-admin-password` with mode 0600.

`./scripts/dev.sh` runs Vite with the API on 4188. For Vite, open `/admin.html`.
The built preview and deployed site use `/admin`.

## What visitors see

- A dark, spacious introduction with a large folded neural brain, direct product
  copy, and an invitation to explore. Company memory is visibly labelled a vision.
- A native compact notch by default. Expand/collapse switches between matching
  native recordings; the compact video remains the single playback clock.
- Speaker-labelled closed captions inside the call. The expanded view preserves
  the recording position and play/pause state; a failed load retains the compact
  view and offers a retry.
- A surface-based brain: a faint continuous cortex, curvature contours, fine
  cells, and 59 baked paths anchored to 40 unique pieces of fictional knowledge.
  Pulses follow the surface rather than cutting through the brain.
- A searchable 3D explorer with type filters, source excerpts, orbit and zoom.
  Opening pauses the call. Closing restores its previous state. A cited moment
  scrolls to the call, seeks to the source, and remains paused.
- A short explanation of capture, connection and recall, followed by the launch
  signup. Mobile uses normal document flow: introduction, brain, call, controls,
  explanation and signup.
- Reduced motion uses a stationary brain and discrete highlights. A matching
  static brain appears while loading and when WebGL is unavailable; the explorer
  retains searchable knowledge and source details.

`src/graph-data.js` supplies the existing fictional knowledge graph and native
recording timeline. `src/brain-motion.js` selects one emphasized relationship per
capture and derives travel progress and bounded rotation from absolute video time.
Travel begins 450ms after knowledge arrives, lasts up to 2.6 seconds, and finishes
before the next arrival. Pause, replay and backwards seeking reproduce the same
state. The final second returns the brain to its opening pose.

The visual demonstrates a **future company knowledge graph**. It does not claim
that document integrations or company-wide recall are currently implemented. This
page does not access the microphone or record the visitor.

## Interest storage and analytics

`POST /api/waitlist` accepts `email`, `consent: "launch-notification-v1"`, the
`website` honeypot, optional `interests`, `session_id` and bounded campaign labels.
Emails are trimmed, normalised and deduplicated. Repeated registrations merge
selected interests and retain the original signup date. It returns the same
success for new and existing addresses. It sends no email.

SQLite is outside `dist/` at `.data/waitlist.sqlite3`, or `CALLA_WAITLIST_DB`.
The schema migration adds fields and analytics tables while preserving existing
emails and consent. Back up the database using SQLite's online backup API before
production changes. Do not copy a live WAL database as a lone file.

`POST /api/events` accepts only the predefined event types and bounded properties:
pageview, engaged, demo_start, demo_interact, demo_25, demo_50, demo_75,
demo_complete, chapter and cta_open. IDs are random UUIDs in sessionStorage;
visits expire after 30 minutes without a recorded interaction. No persistent
cross-site visitor ID, click IDs, complete referrer URLs or raw IP addresses are
stored in the analytics tables. Referrers are reduced to hostnames. Rate limiting
uses transient IPs in memory. Do Not Track and Global Privacy Control suppress
analytics but do not prevent someone from signing up.

Definitions used in reports:

- **Visits** are browsing sessions, not unique people. Pageviews count navigations.
- **Engaged** means at least 10 visible seconds in the page.
- **Demo starts** include muted autoplay; intentional control interactions are
  counted separately. Watch milestones count unique time actually watched, so
  seeking straight to the end cannot create completion.
- **Conversion** is the proportion of tracked visits that produce a new email
  registration in the selected UTC period. Untracked signups still appear as
  signups. An undefined rate is displayed as a dash.
- **Chapter views** require half of the chapter, or half the viewport for a tall chapter,
  to remain visible for a second.
- Campaigns use UTM labels and the first recorded visit attribution. Labels are
  visitor-supplied, not authenticated advertising-platform measurements.

## Private reporting

`/admin` provides 7/30/90-day and custom date filters, trends, funnel steps, demo
milestones, interests, devices, campaigns, lead search and a campaign-link builder.
It refreshes every minute while visible. Report endpoints require the signed admin
session. Login/logout require a same-origin request and CSRF token. Login attempts
are limited. Production cookies are HttpOnly, SameSite Strict and Secure.

- **Export report** creates a 2400×1620 PNG with aggregate figures and charts.
- **PDF** opens the browser's print dialog with an aggregate-only landscape report.
- **Export CSV** uses the authenticated `/api/admin/export.csv` endpoint. It
  includes the selected period's emails, interests and attribution. Formula-like
  cell prefixes are escaped. Browser download policies may block CSV attachments.
- Report images/PDF omit lead email addresses. Local exports explicitly say that
  they are preview data and may include QA traffic. No public engagement counters
  or made-up traction are shown.

For a private server-side CSV export or password reset:

```sh
.venv/bin/python api/app.py export > /private/path/calla-signups.csv
.venv/bin/python api/app.py admin
```

Restart the API after a password reset; it also rotates the stored session secret.
Keep the database, secrets and CSV exports private and out of Git. No advertising
pixels, email delivery service or ad-platform syncing are configured.

## Native footage and visual assets

The native demo is isolated at revision
`a7174d2f4b00729e4e935095fa7ec0f6655ab530`, based on
`dbe4b5e566475073b3adcc0fac52b9dba10e5aff`. `native/weekly-demo.patch`
contains the reproducible exporter and forced-layout changes. The installed app
and production app source are not part of this website work.

The compact `notch-mobile` recording is used at every viewport. `notch-full` is
loaded only when expanded. Chromium uses alpha VP9 WebM; Safari selects HEVC alpha
when supported. H.264 recordings provide the media-error fallback. The native
conversation runs from 3 to 42 seconds, followed by its finishing screen through
45 seconds. History opens after the clip; it is not shown in this recording.

Build and sign the isolated `callaNotchDemo` Release target with bundle identity
`org.calla.notch.landingdemo`, dedicated DerivedData, and the export-only
`native/Export.entitlements`. Export the app’s own view with `--demo-weekly
--demo-immediate --demo-mobile --demo-export /private/tmp/calla-landing-mobile-frames`,
or use `--demo-full --demo-export /private/tmp/calla-landing-frames` for the full view.
Then encode from the repository root:

```sh
python3 website/scripts/encode-demo.py --frames /private/tmp/calla-landing-mobile-frames --name weekly-check-in-mobile --mobile
python3 website/scripts/encode-demo.py --frames /private/tmp/calla-landing-frames --name weekly-check-in-full --stem notch-full
```

`public/demo/provenance.json` records native source, commands and media evidence.
All runtime media, fonts, models and routes are self-hosted.

Brain geometry: Kristen Browne and Heidi Schlehlein, HuBMAP HRA Brain, Male v1.3,
CC BY 4.0. See `public/models/ATTRIBUTION.md` and the visible About panel. To rebuild
the continuous cortex and baked neural assets from `website/`:

```sh
# Asset preparation requires numpy, trimesh, scipy and scikit-image.
python3 scripts/smooth-brain.py
node scripts/prepare-neural-brain.mjs
```

The preparation script simplifies the cortex to 60,000 faces, traces contours of
surface curvature, and computes fold-weighted mesh routes between distinct
knowledge anchors. It emits `cortex.bin`, `cortex.json`, `neural-folds.bin` and
`neural-paths.json`. No route search or anatomical sampling runs in the browser.
The separate explorer layout remains independent of these cortical anchors.
`brain-neural-fallback.jpg` is a browser capture of the rendered brain without labels.

## Validation and deployment boundary

```sh
npm test
.venv/bin/python -m unittest api/test_app.py
npm run build
docker compose -f deploy/compose.yml config -q
```

`review/brain-first.md` records this redesign’s verification and boundaries.
`review/verification.md` and `review/neuron-flow.md` describe earlier designs.
The local browser has Do Not Track enabled; its signup worked while analytics
correctly remained suppressed. API tests independently verify visit attribution,
deduplication, conversion, privacy signals, migration, authentication and exports.

From this repository, deploy or update the site with:

```sh
website/deploy/deploy.sh
```

The script syncs `website/` to `/srv/app/calla-landing` on
`isnakolah@nomonhomelab`, builds the web and API containers, and publishes
`https://calla.nomonlab.com` through the `nomonlab-public` tunnel. The web port
is bound only to `127.0.0.1:4187`; the API and waitlist database stay inside
Compose. The script verifies the local origin, public HTTPS endpoint, and
dashboard login. It keeps the existing waitlist data and dashboard password on
later runs.

`nomonhomelab.com` does not resolve as an SSH hostname from the deploying Mac;
the existing `nomonhomelab` SSH alias does. Override it with
`CALLA_LANDING_HOST` if needed. If the local password file is lost, reset the
dashboard password on the server from `/srv/app/calla-landing`:

```sh
docker compose -f deploy/compose.yml exec -it waitlist python api/app.py admin
docker compose -f deploy/compose.yml restart waitlist
```

Save the new password to `~/.config/calla/landing-admin-password` with mode 0600
before the next scripted deployment, and keep a copy in your password manager.
