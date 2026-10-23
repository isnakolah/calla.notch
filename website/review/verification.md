# Local review evidence

Implemented locally on 22–23 October 2026. Public deployment is pending approval.

- Frontend production build: passed. The 3D renderer is a lazy-loaded chunk;
  Three.js accounts for the build's 500 KB chunk-size advisory (about 144 KB gzip).
- Frontend tests: 6 passed, including watch-progress and campaign collection checks. Graph/timeline assertions They cover backwards seeking, replay without
  accumulated strength, dependency resolution and references to native event times.
- Signup and private dashboard API tests: 12 passed, covering persistence/restart, deduplication,
  validation/consent, origin/content-type restrictions, honeypot, rate limits,
  private storage, oversized requests and storage failure.
- Existing native demo timeline suite: 4 passed. Original adapter self-test and
  weekly adapter self-test both passed.
- Native Release build and signing: passed. The existing package checker also
  passed on a standalone demo DMG: isolated identity, minimal sandbox entitlements,
  9 portable arm64 binaries. This does not establish clean-Mac installation.
- Native media: 141 desktop and 135 mobile frames exported from the real app's
  own view; both encoded videos are 45 seconds. Captions and browser timeline were
  exported from the Swift scenario. Production call-view drawing was not replaced.
- Chrome: native video, WebGL brain, play/pause and keyboard seeking checked.
  Finance remains open at 27 seconds and resolves at 36 seconds. At 41.5 seconds,
  the confirmed plan has stronger connections. Seeks use the video's master clock.
- Responsive: 390px and 320px widths checked without horizontal overflow. Mobile
  selects the real compact-view recording. Temporary viewport overrides were reset.
- Accessibility fallback: reduced motion recognised; deliberately losing the
  WebGL context selected the 2D brain fallback. Browser emulation was reset and
  the page reloaded afterward.
- Visible signup flow: test submission confirmed and database persistence checked.
  Only the exact test address was removed. No email was sent.
- Built-page serving: health check passed; video byte ranges return HTTP 206.
- Docker Compose configuration: passed. Docker daemon unavailable locally, so
  image builds/container runtime and public Cloudflare delivery remain unverified.

Screenshots: `desktop.jpg` and `mobile.jpg`. The page is running on local
`http://127.0.0.1:4187/` with Gunicorn serving the built assets and signup API.

Existing dirty app changes and the other agent's `demo/client-call` worktree
were preserved. Native adaptations are isolated on `feat/landing-native-demo`
at `a7174d2`, with a reproducible patch under `website/native/`.

## Inline signup review — 23 October 2026

- Email and submit button stay inline on desktop and phone, with optional
  interests opening above the row. No signup modal.
- Current desktop and 390 × 844 phone screenshots saved in this folder.
  Phone layout reports 390px document width with no horizontal overflow.
  Temporary browser viewport overrides were cleared.
- Actual browser signup persisted one disposable email with selected interests
  in a separate QA database on port 4189. The primary preview database was not
  seeded with QA leads.
- Browser Do Not Track is enabled and analytics correctly stay suppressed.
  Session/event/conversion behavior is independently covered by API tests.
- Dashboard PNG report was downloaded and visually checked. Print-only styling
  was checked; native Save as PDF was not exercised. CSV API coverage passes,
  but this Chrome profile blocked the browser CSV download.
- Final production build and 6 frontend / 12 API tests pass. The API storage-error
  log during testing is an intentional failure-path assertion.
- Main preview remains on 4187. No SSH, DNS, or public deployment was performed.
