# One meeting, and the published spec — 6 September 2026

Two changes. The live call is now the Wave interview and only that, with one
fixed meeting identity every session belongs to; and the `wave-v1` pack states
the published specification as fact instead of paraphrasing it, with preparation
checking every documented fact against the installed libraries.

## What was actually wrong

The meeting never reached the call. All the machinery existed — knowledge
scopes, call rows, history joins, per-call frozen packs — and nothing fed it.

- The notch's Call start passed no meeting (`CallaCopilotTabView.swift`, old
  `start()`); only the calendar's Join ever did.
- `startCodingInterview` resolved a meeting for the *setup* and then dropped it
  before `startCall`, so even a Wave session ran a meeting-less call.
- Which meeting Code thought it was in came from the clock: calendar events
  within ±1 hour that had their own setup. A rehearsal on Sunday resolved
  nothing; Monday would resolve something else.
- Consequently retrieval collapsed to `[.always, .persona]` and the `call` row
  had no `event_id`/`series_id` to group on.
- The call was not pinned to the interview persona either — the default was
  `generic`, with a four-way picker in the notch.

## One meeting

`WaveInterview` (`boringNotch/components/Calla/WaveInterview.swift`) is the only
place that says what the interview is: `series wave-interview`, `event
wave-interview-2026-09-07`, Monday 7 September 12:00–14:00 Africa/Nairobi, the
`interview` persona, the `wave` profile, 120 planned minutes. Both ids are
carried because they do different jobs: `MeetingContext.scopes(persona:)`
appends series then event, and `calls(forEvent:seriesID:)` prefers the series.

The identity is deliberately independent of the project folder — the folder is
expected to change between scenario runs — and independent of EventKit, so a
session started today lands in exactly the scope Monday's will.

Every start path now carries it: `startCodingInterview`, `resumeCodingInterview`,
both startup-failure retries, the global shortcut, and Settings' Start call, all
through one `startWaveCall`. The `interviewProfile` is forced rather than read
from a setup row, so a session cannot start without its context pack or its
two-hour budget. The calendar's Join no longer starts capture at all: it was the
last path that could run the interview persona against an unrelated meeting.

`CallaMode` collapses to `interview | quiz`; stored `call` and `code` fold onto
`interview` on every launch, as does the persona. The generic Call card and its
persona picker are gone.

## Sessions stay independent

Attaching a meeting is exactly what would switch summary carry-forward on, so
this is a guard rather than a feature. `finish(summary:meeting:)` is reached only
from tests; the live end-of-call path deliberately files no knowledge, and the
one promotion path stays the Approve button on a recap draft. Two tests hold
that line: a finished session indexes nothing, and an approved recap is filed
against the series.

## The spec, as fact

`wave-v1` gains `spec.md` (all 18 published `parse` examples, the full `Range`
surface, operator and circular-reference rules, and the interviewer's own
grading order) and `part1-baseline.md` (the `Spreadsheet` and `Index` interfaces
the project already has, and the fact that `print()` is swallowed by the curses
UI so logging goes to `spreadsheet.log`). `flow.md` carries each step's
acceptance; `codebase-and-interfaces.md` is trimmed to what the spec genuinely
leaves open.

`WaveInterviewState.ladder` now states those checks in code, and they reach the
coder prompt and Call's task context — so the worker is told what the edit has
to handle, not just the behaviour's name.

## Preparation is a conformance probe

`WaveSpecConformance` (CallaContracts) holds every documented fact and generates
the probe from it, so the pack and the probe cannot drift. Preparation runs 41
assertions and writes `library-probe.md` as a table of differences, with matches
collapsed to a count per library.

Material intake now runs `git bundle verify` first, from the part 1 branch root,
matching the published procedure — a corrupt bundle used to fail as "does not
supply a part2 branch". The staged merge is a merge, never a rebase, matching
`git pull --no-rebase`.

## Verified

- Contracts 71 + 11, Intelligence 407 (5 skipped) + 7, CallHost 154 (1 skipped),
  engine validation 206 (1 skipped) + 7. No failures. Debug and Release builds
  of the app succeed.
- The generated probe was run against a reference `sheet` package written only
  from the documentation: 41/41 as documented, and the generated Python parses
  and runs.
- Against a copy of that library with three plausible departures — quotes kept
  on a quoted literal, `indices` iterating column-major, `contains` treating
  `last` as exclusive — the report named exactly those three rows and nothing
  else.
- A regression caught while writing the tests: Swift's synthesized decoder throws
  on a missing key rather than using the property's default, so adding `checks`
  to `WaveTaskState` would have broken Resume for any session sealed by an
  earlier build. `WaveTaskState` now has a hand-written decoder.
- Two other defects fixed on the way: the session workspace seeded
  `persona: "generic"` while the worker pool seeded `"interview"` (and no
  `coding/personas/interview.md` existed, so the pool silently fell back to
  generic — the file now exists and both use it); and Resume rebuilt the
  workspace without re-seeding the Wave context, so a session resumed after a
  restart read the spec, the flow and the library probe as missing files.

## Still outstanding

Everything installed. No live speech, capture, window observation or latency
measurement was exercised here, and the two-hour rehearsal in
`implementation-status.md` remains outstanding. The conformance probe has been
run against a reference library, never against the actual supplied part 2
bundle — that is the first thing Prepare should do with the real materials.

---

# Second pass, same day — rehearsal mode, and two regressions

## Regressions from the first pass

**The prepared project became unreachable.** The setup with the folder, brief,
rubric and task order was filed under `scope: event, scopeKey:
C071EF03-…` — a real calendar event. Resolution only looked at the interview's
series row and the `always` row, so the notch said "No project set up yet" over
a project that was right there on disk. Fixed twice over: a one-time,
non-destructive adoption copies the most recently prepared setup that names a
folder into the interview's scope, and resolution falls through to any row with
a folder rather than giving up.

**The mode switcher truncated.** Its segments were a fixed 44pt, chosen when
every mode was a four-letter word; "Interview" rendered as "Interv…". Segments
now size to their label with a 44pt floor.

## Rehearsal mode

The interview is tomorrow and the only way to know any of this works is to run
it today. `WaveInterview.Session` is `rehearsal | sitting`, chosen from the
notch's context chip and refused while anything is live.

Both are sessions of the same meeting — same `seriesID`, so the same project,
brief, attached material and History group. They differ by occurrence:
`wave-interview-rehearsal` against `wave-interview-2026-09-07`. That single
difference is what carries the rest.

- The chip and the state cap both say "Rehearsal", so which run this is is never
  something to remember.
- History badges rehearsal rows inside the same interview group.
- An approved recap is filed at the narrowest scope its meeting has, and the
  engine drops the series for a rehearsal row — so a practice conclusion lands
  on the rehearsal's own occurrence and cannot be retrieved during the sitting.
  Approving is still not a no-op.
- `CodingSessionConfiguration.rehearsal` reaches the engine, which tells the
  coder and Call's task context. `nil` reads as a rehearsal: a configuration
  written before this existed cannot vouch for having been the real sitting.
- Default is `rehearsal`, and an unrecognised stored value is one.

## The plain call is back, behind a switch

The first pass deleted the generic Call surface outright. It is restored as
`CallaCallPreflightView` behind `callaPlainCallEnabled`, off by default —
Settings › Copilot › Call. On, it adds a third segment to the switcher; off,
the notch is the interview and Quiz. A call started there still carries no
meeting by design: it is not a session of the interview, so it must not retrieve
the interview's knowledge or land in its History group. `CallaMode.resolved`
falls back to the interview when a stored mode's setting has since been switched
off, so turning one off cannot strand the notch on an unreachable surface.

## The brief is prefilled from the spec

The brief fields started empty with placeholders, which meant typing the
published spec out by hand, correctly. `applyPublishedBriefIfEmpty` fills the
title, rubric (the interviewer's own ranking), task order, supplied interfaces,
depriorities and constraints from the spec. Applied only to an empty brief —
someone who wrote their own reading of the rubric meant it — and offered as
editable text that is only written on Save.

## Verified

- Contracts 71 + 11, Intelligence 410 (5 skipped) + 7, CallHost 154 (1 skipped),
  engine 206 (1 skipped) + 12. No failures. Release built and deployed.
- New tests: both runs share the series and are one History group; a rehearsal
  retrieves the interview's material; an approved rehearsal recap is scoped to
  the rehearsal occurrence and does **not** surface in the sitting's retrieval;
  an unknown stored session value is a rehearsal; only switched-on modes are
  offered and a switched-off one falls back rather than stranding.
- Installed bundle confirmed to carry `wave-interview-rehearsal`, the plain-call
  setting, the prefilled brief constraints, and the engine's rehearsal prompt.

## Still outstanding

The setup adoption is lazy — it runs the first time the Copilot surface is
opened — so it had not fired at the moment of this check. The notch's fallback
finds the project either way. No live speech, capture or window observation was
exercised, and the conformance probe has still never run against a real
`part2.bundle`.

---

# Third pass — the real project, and four live-panel defects

## Verified against the actual repository

`/Users/isnakolah/dev/WaveInterview/spreadsheet`, branch `part1`, clean. The
whole preparation sequence was reproduced outside the app against it: shadow
copy, Python-root discovery, venv, dependency install, conformance probe.

    sheet.formula: not installed (arrives with the part 2 bundle)
    sheet.models.Range: 11/11 as documented
    sheet.models.Index: 12/12 as documented

The shipped `Range` and `Index` match the published documentation exactly —
inclusive endpoints, reversed-endpoint normalisation, row-major `indices`,
`contains`, `row(i)`, `ValueError`, the repeated-letter `column_label` scheme
(col 27 → `BB`, col 53 → `BBB`), and `__add__` with both an Index and a tuple.
Nothing to raise with Angel on those two.

## The project folder is the repository root, not `python/`

Found by testing, not by reading. The two halves of preparation wanted different
directories:

- Material intake **must** have the git root: `git clone` of
  `.../spreadsheet/python` fails outright with "repository does not exist", and
  the published procedure runs from the part 1 branch root anyway.
- The venv, `requirements-dev.txt` and the `sheet` package are all in `python/`.
  Preparing at the repository root left `import sheet` failing, so the probe
  reported nothing at all.

`CodingSessionController.pythonRoot(in:)` now locates the package inside the
copied tree — the root, else one level down, else the root unchanged — and the
venv, the install and the probe all run there. The preparation report names the
subdirectory when it is not the root. Two related fixes: `requirements-dev.txt`
is recognised (only `requirements.txt` was), and the helper returns a child of
the caller's own root rather than an enumerated, symlink-resolved URL.

**Select `/Users/isnakolah/dev/WaveInterview/spreadsheet` as the project.** The
engine finds `python/` inside it.

## The report led with the wrong thing

Against the real project the first run said "41 of 41 documented facts do not
hold" and printed 41 rows of `NameError`. True, and useless: the cause was one
line — `sheet.formula` is not installed yet. The report now leads with what did
not import, counts those facts as unchecked rather than failed, and still gives
a real verdict for the libraries that are present.

## Live panel

Four defects, all visible in the notch during a rehearsal:

- **A failure and its recovery were concatenated with a space**, producing "AGY
  attempted a disallowed tool: run_command Continue speaking or save to retry
  preparation." and "The coding response exceeded its time budget Please repeat
  that point to retry." They are separate blocks now, in three places.
- **The step's `why` was printed twice** — in full in the reading pane and again,
  truncated, in the WHY row directly below it. The WHY row now falls back to
  `why` only when the pane is showing code.
- **A background failure displaced the reasoning.** Timeouts and refused tools
  are transient and self-healing, and none of them is actionable while someone
  is waiting for you to speak. They appear only when the pane would otherwise be
  empty, and as a notice — attention glyph, its recovery on its own line —
  rather than as more prose in the same weight.
- **"Still to cover" was clipped by the panel's bottom edge.** It is a reference
  read between steps, not mid-sentence; it moved to the reference surface
  (⇧⌥⌘E), where it is shown whole instead of truncated to four.

## Agent permissions

Private proposal jobs now get command tools. Each owns a throwaway copy of the
tree, so running the project's own tests against its own edit is the point of
one; they stay inside `sandbox-exec`, whose profile permits exec but confines
every write to the workspace.

More importantly, **a refused tool no longer destroys the turn**. It was thrown
mid-stream, so a model that reached for a shell, was refused, and then answered
anyway had its answer discarded — an empty panel mid-interview. The refusal is
remembered and only becomes a failure if the turn produces nothing.

The live conversation lane stays read-only and without commands, deliberately:
it answers mid-sentence, and a command there would block the answer being waited
on. The non-fatal change removes the failure mode there without that cost.
`coding/agents.md` now states the rule as its own paragraph rather than a clause.

## Verified

Contracts 71 + 13, Intelligence 410 (5 skipped) + 7, CallHost 154 (1 skipped),
engine 206 (1 skipped) + 18. Release deployed.

New tests: Python-root discovery at the root, one level down, from a project
file alone, with no Python at all, and stable across runs; a missing module
reported as missing rather than as eighteen failures; a missing module not
masking a real difference elsewhere.

## Still outstanding

The folder itself must be chosen in the app — it is stored as an app-scoped
security bookmark, which only the sandboxed app can mint. No live speech,
capture or window observation has been exercised, and the probe has never run
against a real `part2.bundle`.

---

# Fourth pass — the master plan, and the task wiring

## Correction to the previous pass

I wrote that `prep/part-2/` was empty and no part-2 plan existed. **Wrong** — a
truncated `ls -R` hid it. It holds a 61KB mastery lab (`mastery-part2.md`,
`02-part2-lab.ipynb`) covering the same six slices, the cycle shapes, the seam,
the dates matrix and the `sqrt` registry.

That mattered, because the lab's design differs from the one I had written:

- **The seam.** The lab's §6.2 says `=` should mean `parse` *always*, and `=A1`
  should work because `'A1'` is a leaf that resolves — "the old path is now a
  special case of the new one, which is the sign of a seam in the right place".
  I had kept `_reference` beside the parser, which is precisely the shape the
  lab identifies as the tell that the seam is wrong.
- **The vocabulary.** The lab teaches one new class, `FormulaError`. I had
  invented `BadFormula` + `BadArgument`.
- **The name.** The lab calls it `evaluate_node`.

The reference implementation was rewritten to the lab's design. Introducing a
second, competing design into someone's head hours before a pairing interview
is worse than any merit the alternative had.

## `prep/part-2/` — the master plan

Outside the git repo, because `plan/architecture.md:24` says part-2 drift is a
scope breach *visible in a diff*.

- `master-plan.md` — the design, per-task landing sites, every edge decision
  pre-made, the open questions for Angel, and a pre-flight checklist.
- `reference/evaluate.py` — `evaluate_node(node, resolve) -> CellValue`, pure,
  taking a resolve callable rather than a `Spreadsheet`.
- `reference/{values,engine,errors}_patch.py` — the one branch, the one case,
  the one class, as copy-in fragments with the reasoning attached.
- `reference/formula_stub.py` — the spec-conformant parser validated earlier
  this session, so the whole thing is rehearsable before the bundle exists.
- `drills/` — **82 checks**, one command, against a scratch copy of the real
  repo: the 18 published `parse` examples, the `Range`/`Index` facts, every
  check from all six tasks, and characterization tests pinning part-1 behaviour.

Verified: `bash drills/run.sh` → 82 passed. The design works against the real
`engine.py`/`values.py`/`formats.py`, including the case the whole thing turns
on — `A1: =A2 + 1` with `A2: =A1` gives `#CIRC!`, because `visited | {index}` is
threaded into the evaluator's resolve closure.

Two live hazards found and written into the plan: `^Y`/`^S` call
`Spreadsheet.copy`/`.sort`, which do not exist, and take the app down through
`curses.wrapper`; and `_log_once` calls `logging.exception(message, index)`, so a
new handler whose message lacks a `%s` raises `TypeError` *inside* the except
block and escapes `get_formatted` — the one contract the design protects.

## App fixes

**The acceptance checks followed the wrong task.** `scheduleWaveSteps` built its
acceptance string from `status.wave?.currentTask?.checks` while the loop coded
`task.text` from `flow.pending`. `currentTaskID` never moved, so the coder was
told "Prepare only this behavior: sum" with the cell-reference checks pasted
after it — on every prompt after the first. My bug, from when I added the
checks. Now keyed on the pending item's own id, and the planner gets them too.

**A live check could not run.** `beginPendingRun` ran at the copied repo root
while the package sits in `python/`, so every check was a
`ModuleNotFoundError` and `.checked` evidence was unobtainable. It now defaults
`relativeCWD` to `pythonRoot(in:)`, treating both `""` and the contract's `"."`
as unset.

**No runnable check was suggested.** `suggestedCommands` matched root-level
markers only, so this repo yielded `make test` — a target its Makefile does not
define. Now matches a Python project one level down (`pytest.ini`,
`requirements-dev.txt`, `pyproject.toml`) with the right `relativeCWD`, and
offers `make check`, which is the gate this project actually has.

**The model rediscovered the project live.** Prepare now writes
`project-map.md` from the selected tree — every module's `__all__`, class and
function signatures, and the private helpers a step must name to be actionable.
Signatures only, never bodies, since it runs against a tree that may contain
part-2 work. Verified against the real repo: it names `_evaluate`, `_log_once`,
`_reference`, `_number`, `_date`, `_default` and each module's exports.

**The ladder never advanced.** Continue authorized the next stage and never
touched `status.wave`, and `.saved` evidence was never recorded anywhere, so
`advance(explicit:)` had no production caller and its automatic path could not
fire. Continue now advances the cursor, and a save records `.saved` evidence at
the revision it produced.

## Verified

Contracts 71, Intelligence 410 (5 skipped), CallHost 154 (1 skipped), engine
206 (1 skipped) + 37 swift-testing across 9 suites. Release deployed and the
installed engine confirmed to carry the project map, the per-task acceptance,
and both new check suggestions.

New tests: every ladder task resolves its own checks and not the first task's;
an unknown pending id contributes nothing rather than the wrong thing; a
subdirectory project supplies the working directory; one Makefile target is
offered, not three; the project map names exports and private helpers and ships
no bodies.

## Still outstanding

The `.hardening` cue table cannot authorise `dates`/`sqrt` by voice, and
`resume` does not rebuild `pending` — both deliberately left, as planned. No
live speech, capture or window observation has been exercised. The transcriber
watchdog is still not built, and the whisper Metal stall that made a call look
healthy while deaf is still unguarded.

---

# Fifth pass — the bundle flow is gone

Supplied part-2 files go straight into the working folder. The import path is
removed rather than left unused.

## What went

- `BoringCallaEngine/WaveMaterialIntake.swift` — deleted, with its four tests
  and its entry in the root `Package.swift`. It was untracked, so a copy is in
  the session scratchpad as `WaveMaterialIntake.swift.removed`; git has never
  seen it.
- `WavePreparationRequest.materialBookmark` — removed from the contract, so the
  request is now just the project.
- `prepareWave`'s intake step, and `WavePreparationResult.recoveryDirectory` no
  longer being populated — there is no staged merge to recover from.
- The "Attach supplied bundle…" button in `CopilotCodingPane` and "Attach
  bundle…" in `WavePreparationControls`, with their bookmark and name state.
- The bundle procedure in `spec.md` and `arrival-and-rehearsal.md`, and the
  `--supplied` wording in the drill runner and the master plan.

The gain is not just less code: with no import step the tree Prepare probes is
the tree the session runs against, and the two cannot diverge. `sheet/formula.py`
appearing in the package is now what "the library has arrived" means.

## The default folder

`WaveInterview.defaultProjectFolder` is `~/dev/WaveInterview/spreadsheet`. It is
a **hint, not a grant**: the app is sandboxed and a usable folder bookmark can
only be minted from a folder the reader picks, so both folder pickers now open
there and the empty state names the path. It cannot attach the folder silently,
and pretending otherwise would be the wrong shape.

## Verified

Contracts 71, Intelligence 410 (5 skipped), CallHost 154 (1 skipped), engine 202
(1 skipped, down four with the intake tests) + 37 swift-testing. Drills still
82 passed. Release deployed, and the installed binaries confirmed: no
`git bundle verify` left in the engine, no attach button in the app, the default
path present, and the rewritten arrival section shipped in the pack.
