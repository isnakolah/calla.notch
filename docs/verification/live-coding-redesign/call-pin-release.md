# Call pin release — 5 September 2026

A universal pin set during an interview used to persist as an ordinary notch
pin. `close()` respected that pin after the call ended, leaving the old panel
open. In addition, the recap transition could acquire a new session pin after
End, and a previously dismissed session could skip terminal layout cleanup.

Pins now record whether they were set on an interview or an ordinary tab. End
immediately releases interview presentation and retires interview-owned pins.
Recap and delayed capture/startup updates cannot reopen the ended presentation.
The release is consumed once per view, so later navigation is not repeatedly
closed by recap updates. A fresh explicit Call/Quiz Start re-enables presentation.
An ordinary pin set outside an interview is retained, but the ended interview
layout is replaced by the normal Home size. With the pointer over the notch,
Home remains until hover-out; keyboard End releases it immediately.

The viewport's event wiring was also split into smaller SwiftUI expressions to
resolve a compiler timeout in the current worktree. A misplaced frame modifier
was reattached to the reader while preserving the existing interview-flow changes.

Verification:

- Nine sizing/pin tests pass: `/tmp/call-pin-tests.log`.
- `python3 scripts/verification/verify_call_pin_release.py` extracts production
  transition methods and exercises both capture/recap shutdown orders, stale
  capture/startup updates after End and a new explicit Start. It passes without
  audio capture. Log: `/tmp/call-pin-transition-probe.log`.
- Release build: `/tmp/call-pin-final-release-build.log`.
- Deployment: `/tmp/call-pin-final-deploy.log`.

These are source/transition tests and installed build checks, not a complete
installed live-call or multi-display interaction rehearsal.
