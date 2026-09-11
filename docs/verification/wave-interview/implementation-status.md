# Wave implementation and verification — 5 September 2026

> Latest UI update: the user superseded the independent Wave size. Live Coding
> now shares normal Call sizing, displays code in compact mode, and exposes
> keyboard shortcuts and step arrows. The window catalog now includes other
> Spaces and the installed build finds the spreadsheet VS Code window. See
> [current UI evidence](../live-coding-redesign/README.md). The broader remaining
> interview preparation and two-hour acceptance work below is still outstanding.

This work is **not yet fully accepted for the interview**. The earlier Release
was installed successfully. The latest model-picker, coordinated question routing,
conservative saved-code progression and intake changes pass the Release build.
The signed Release update was installed and relaunched successfully at 05:44
Nairobi (02:44 UTC). No two-hour installed rehearsal has been completed.

## Reviewable implementation areas

- `CallaContracts/WaveInterviewContracts.swift`: revision identity, task evidence,
  suspended work, question ownership, reading state and worker admission.
  Optional fields preserve older configuration/snapshot decoding.
- `BoringCallaEngine/WaveMaterialIntake.swift`: private bundle staging, prerequisite
  checks, dirty/conflict rejection, recovery bundle and index patch, repeat import,
  and late-material replacement when earlier staged changes are still unmodified.
- `CodingSessionController.swift` and `WaveWorkerPool.swift`: Wave task state;
  Call owns remote answers; planning, coding and conditional review use separate
  proposal copies and conversations. Saved-source/requirements revisions reject
  stale results. Shadow results cannot automatically complete interview tasks.
  Local spoken help uses Call's queue with stable retry identities. Accepted
  questions publish immediately, independently of answer completion. Failed
  submissions report that they were not queued.
- Saved-code progression requires a complete proposed block in a changed saved
  file, a successful task check on an exact saved copy, and a literal readiness
  cue after the save. The check cannot modify that copy or advance across an
  intervening source, requirement or task change. It never dismisses an answer.
  Alternate implementations and ambiguous cues preserve the current step.
- Proposal paths are retained inside encrypted session history and validated on
  recovery. Read-only context directories are thawed only after workers stop and
  the encrypted archive commits, allowing plaintext cleanup.
- `CallaCopilotTabView.swift`: dedicated Wave reading viewport, selectable syntax
  colored code, stable per-item native scroll offsets, answer interruptions,
  Hold/unread, manual questions, follow-ups, history, transcript and evidence.
- Sizing/preferences/window geometry: independent 740×420 Wave profile, bounds
  600×360–1000×700, display clamp, matching resize profile and enlarged canvas.
  Wave transparency is independent; Reduce Transparency uses an opaque fallback.
- Settings and context pack: project/bundle Prepare, actual parser/range probes
  in private work, selected VS Code window observation, versioned five-file pack.
- Model menus now query the current AGY catalog, retain selected IDs on catalog
  failure and offer Refresh. Named thinking presets omit a second effort picker
  and omit the CLI effort override. Other models retain adjustable effort.

## Verified evidence

- Latest engine suite: 147 passed. Latest CallHost suite: 152 tests, 1 skipped,
  no failures. Latest focused Wave contracts: 11 passed, including coordinated
  request identity, older command decoding, readiness rejection and preventing
  verified saves from dismissing answers. Earlier full Intelligence suite: 386
  tests, 5 skipped, no failures; original full contracts suite: 59 passed.
- Real AGY workspace tests: 2 passed, including readable private context/work roots.
- Bundle fixtures: clean import, idempotent repeat, unrelated dirty work,
  merge conflict, and late material replacing an unmodified earlier import.
- Live catalog contains Gemini 3.8 Flash High/Medium/Low. A direct 3.8 Flash Low
  request without an effort override returned SUCCESS.
- Synthetic CLI load probe: two warm Flash Low conversations, two background
  model requests, six short answers; median 1408.1 ms, slowest 2010.9 ms.
  `cli-load-probe.json` is raw timing evidence. This excludes ASR, socket/XPC
  delivery, notch rendering and a concurrent verification command. Six samples
  do not establish production p95 or the installed latency targets.
- Release build and signed deployment succeeded; installed Settings exposed the
  Wave toggle, window picker, Prepare and independent transparency. A Settings
  screenshot is not acceptance of the live notch's layout.
- Final installed-update log: `/tmp/wave-installed-update.log` ends `Deployed`.
  After relaunch, CUA could inspect VS Code but exposed only an empty notch system
  dialog; app-menu Settings and the registered notch shortcut did not open a
  Settings surface. Final dropdown screenshot and live-notch layout checks remain
  unverified. This is a UI-verification limit, not proof that the menu failed.

## Remaining implementation and acceptance work

- Exercise saved-code advancement and spoken-help routing in the installed flow.
  Deterministic contract tests and a Release build do not prove speech/ASR timing,
  check quality or real source-window behavior. Automatic advancement deliberately
  falls back to Continue for alternate implementations and ambiguous readiness.
- The fast Call model remains governed by normal Call provider/tier settings;
  the Code Move model selector is not an exact-model selector for that transport.
- Preparation probes the library but does not yet maintain a warmed, reusable
  intake/answer/coding worker set. Prepared dependency environments are not yet
  propagated to every independent proposal copy.
- Complete scope inference for requirement corrections and deep library/reviewer
  coverage before relying on unattended live progression. Current corrections
  conservatively invalidate future moves. Verify restored proposal execution in
  the installed app; path validation and recovery are implemented.
- Choose Monday's actual project and supplied materials; verify their APIs and
  run targeted types/ranges/dates/repeated-reference/cycle drills against them.
- Inspect the installed live notch at default/min/max sizes over bright/dark
  VS Code, including long code, long paths, history, Hold and exact return offsets.
- Measure speech-end-to-visible answers with two background models plus a
  verification command; measure accepted prepared-step publication to visibility.
- Run the complete two-hour installed mock, including general/manual/follow-up
  questions, attached knowledge, recap, material arrival and a changed sum rule.

The dirty baseline was preserved in `/tmp/wave-baseline.patch` and
`/tmp/wave-baseline-untracked/`. The pre-install app backup is
`/tmp/wave-before-install.app`. No commits or pushes were made.
