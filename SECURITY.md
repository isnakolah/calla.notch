# Security Policy

## Reporting a Vulnerability

Security reports for this customized fork belong in its repository. Do not include credentials, transcripts, captures, or private endpoints in a public report.

To report a security issue, please use the GitHub Security Advisory ["Report a Vulnerability"](https://github.com/isnakolah/calla.notch/security/advisories/new) tab.

Report security bugs in third-party dependencies to the person or team maintaining the package or dependency.

## Tutor captures and intelligence

- Calla Engine owns Tutor run state, encrypted capture history, provider routing and progression. TutorHost never persists captures in Engine mode; Gateway never receives Tutor action or verification authority.
- Screenshot capture is limited to focused allowlisted target window. Missing Screen Recording permission, changed focus/window identity, protected/blank/oversized content and failed validation reject capture. No display fallback.
- Calla encrypts persisted JPEG captures with AES-GCM using this-device-only Keychain key. Capture and pending sanitized history commit before provider transmission. Missing/wrong key or storage failure blocks feedback and sends nothing.
- Local `agy` is process-local, not on-device inference: it can transmit target-window screenshots to Google Antigravity-backed remote models. Gateway feedback can also transmit screenshots to configured provider. Provider-side retention is outside Calla deletion control.
- Model replies are bounded feedback JSON only. They cannot choose a target, send Host commands, perform actions, determine pass/fail, or advance a lesson.
