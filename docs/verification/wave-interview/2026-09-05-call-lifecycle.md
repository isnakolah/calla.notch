# Call and Code lifecycle regression — 5 September 2026

The user's 13:36 Nairobi attempt did start Call capture. The corresponding Code
session incorrectly timed out after 35 seconds, then could not dismiss its
already archived interrupted state when End was pressed.

## Evidence from the attempt

- Call `call-3b570b07-2bcb-4f`: microphone and system audio both active at
  10:36:19 UTC / 13:36:19 Nairobi. Three transcript turns were recorded.
- The encrypted Code manifest for `code-4b7c6b77-12b6-48bd-9788-818aab0fb7cd`
  names that same call and generation 1. It transitions preparing → ready →
  interrupted, with no capturing transition. Elapsed time: 35.22 seconds.
- Call capture continued until the user's stop at 10:37:46 UTC. The coding
  message “the call never started” was therefore false.
- The status monitor skipped lifecycle reconciliation when its weak observer
  table was empty. XPC observer proxies were not retained for the subscription.
  The separate 35-second task only checked Code's ready state.
- After archival, `configuration` was cleared. Pressing End re-entered `end`,
  returned on that nil configuration, and left the interrupted snapshot intact.
  The view explicitly rendered interrupted sessions as live panels.

## Changes

- Retain XPC observers until connection shutdown. Reconcile Code directly from
  matching typed Call lifecycle events and monitor it independently of subscribers.
- Recheck live Call state at the startup deadline; scope delayed interruption to
  the original coding session and generation. Starting/capturing Call must not be
  treated as an absent call.
- Distinguish normal Call stop from interruption. Use truthful interruption text.
- End on an already archived session clears the active presentation and keeps
  its history. Terminal sessions return to setup, where Resume remains available.
- Restore listening presentation on resume instead of retaining Ended text.
- Show the VS Code window picker directly below the project in both default and
  meeting setups. Window observation is independent of Wave appearance, starts
  with the session, and remains locked to the selected window identity.

## Verification

- Release build: `/tmp/wave-lifecycle-fix-build.log`, succeeded.
- Contracts: 67 tests, no failures, including the actual capture-event shape,
  different-call/generation rejection, capture-not-yet-active, and normal end
  versus failure. Log: `/tmp/wave-call-lifecycle-tests.log`.
- Actual `CodingSessionController` probe using temporary project/storage:
  `/tmp/wave-coding-lifecycle-probe.log`. Passed capture followed by startup guard,
  normal stop, an old timer against a new session, actual startup interruption,
  End after archival, retention of both histories, and unchanged selected files.
  It did not start microphone or window capture. The unused capture runner was
  replaced with a fail-fast sentinel in this lifecycle-only probe.
- Signed installed update: `/tmp/wave-window-lifecycle-deploy.log`.
- The user's existing interrupted archive remains intact. No new live recording
  was started as part of this fix. Full installed speech/window acceptance and
  the broader two-hour Wave rehearsal are separate outstanding checks.
