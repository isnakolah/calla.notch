# Live Coding: intent, continuity, and a readable next step

Date: 2026-09-05. Scope: technical interviews in the Live Coding role.

## Product contract

The candidate should be able to glance at the notch and understand the next useful
step, why it fits the interviewer’s request, and what remains unverified. Keep the
current move readable while a new request is processed. Preserve explicit Start,
the candidate-owned project, shadow execution, and the selected AGY model.

The experience has three layers: a small activity line, a dominant next-step column
(explanation, code, reason, caution), and supporting interview context and check
evidence. Reserve space for controls so they never cover code. Older moves remain
browsable; a new move should not reset a reader reviewing history. Show the source
question for a move when its transcript anchor is available. A proposed command
must remain visibly distinct from a completed check.

## Source audit

- `CodingDirector` routes all remote questions to explanation, including requests
  for implementation, commands, and design. Substring matching also treats
  reported or negated actions as requests.
- `CodingSessionController.consider` silently drops an actionable remote statement
  whenever `guidanceTask` is occupied. Local requests can be suppressed by typing
  and in-flight guards before intent is evaluated.
- A failing-check reminder takes precedence over a request to explain that failure.
- The frame takes the default cadence increment, while publication uses the
  director-selected increment. The model can therefore be asked for a different
  step than the engine permits.
- The worker’s live path still uses schema enforcement and a 20-second ceiling;
  the declared six-second task budget is not enforced by this worker. No new
  latency claim is justified without a live provider measurement.

## Implementation decisions

1. Classify intent locally, without adding a model round trip. Recognize direct
   requests, follow-ups, constraints, corrections, and hints. Match word boundaries,
   normalize speech punctuation, and reject common reported/negated action forms.
   Ambiguous or truncated speech gets a clarification move, not invented intent.
2. Give explicit requests precedence over repeated clock/check reminders. Keep
   ordinary narration and acknowledgement quiet. Respect the existing cadence
   when deciding how much code to offer.
3. Serialize actionable work in a bounded FIFO queue. Preserve independent
   questions; expose overload instead of silently discarding them. Recompute the
   permitted increment when work starts. Fence publication by session generation,
   source revision, cancellation, and task identity.
   Snapshot the preceding exchange when a request is accepted so a queued
   follow-up retains its referent. Carry original transcript sequence IDs across
   XPC; event sequence numbers are not transcript anchors.
4. Send the selected increment, bounded brief, recent transcript, current
   interviewer constraints, and last run evidence inline. That reduces avoidable
   context-file reads without pretending the model has inspected project files.
   Keep constraints apart from model suggestions; a suggestion is not a confirmed
   interview decision. Latest explicit corrections outrank older assumptions.
5. Use the live task’s six-second ceiling after the worker is warm, with a separate
   cold-start allowance. Keep schema validation until a measured transport change
   proves equivalent parsing reliability. Report timeout honestly and allow retry.
6. Improve the actual SwiftUI surface: contextual request, next-step label,
   readable reason/caution, proposed check, and dedicated control space.
7. Distinguish requests about execution from execution cues. A candidate saying
   “How do I run the tests?” or reporting a previous run must not execute a staged
   command. Completed coding requests use the short dispatch gap; hanging
   fragments wait for their continuation.

## Ownership and compatibility

The engine owns scheduling and revisions; IntelligenceCore owns deterministic
intent and framing; the worker owns one serialized conversation; SwiftUI renders
engine facts. Keep existing contracts and archived sessions readable. Additional
inline context has strict character limits. Frozen briefs and project excerpts
remain data, never tool authorization. AGY processes transcript and project context
remotely; existing disclosure remains applicable. No new provider or capture trigger.

## Validation and release boundary

Replay tests must cover remote code/run/design requests, a request during another
request, follow-ups, changed constraints, negation, reported speech, uncertainty,
typing, and failure recovery. Frame tests cover bounds and corrected context.
Build the app to verify engine and SwiftUI integration. Keep existing unrelated
worktree changes intact.

Installed acceptance must separately measure speech-end → detection → request →
validated move → visible panel, cold and warm, with rapid questions and source
changes. Targets: no silently lost accepted request; no stale publication after
end/restart; warm provider work capped at six seconds; readable controls and code
at supported notch sizes. These are targets, not measured results. Broader accuracy
needs a labeled interview corpus and live speech/provider trials.

## Verification recorded on 2026-09-05

- Intelligence suite: 386 tests, five opt-in tests skipped, zero failures.
- Engine validation suite: 142 tests, zero failures.
- Contracts suite: 52 tests, zero failures, including older command decoding and
  transcript sequence round-trip.
- Follow-up focused checks cover the final intent, director, framing, queue, and
  segmentation edits. Debug Xcode app build and whitespace validation passed.
- A temporary harness exercised the actual `CodingAgyWorker` against three
  synthetic Python interview questions using the default flash model and the
  normal schema path. All returned decodable drafts: cold 10.652 seconds; warm
  1.410 and 2.010 seconds. The fixture workspace and isolated credentials were
  removed when the harness finished. These timings are provider round trips,
  not audio-to-panel latency, and three requests do not establish an accuracy rate
  or a latency distribution.
- No deployment or installed UI/audio acceptance was performed. The built app
  includes the existing dirty-worktree baseline. Source backups for the main
  edited files and the initial tracked diff were retained under `/tmp`.

Remaining limits: intent detection is heuristic; arbitrary indirect requests and
long compound corrections need corpus evaluation. Cold startup is still slower
than warm operation. The six-second warm ceiling is proven only against this
small default-model sample; timeouts remain explicit and recoverable. The existing
worker still combines response generation and shadow edits; separate planning
and editing lanes are a larger subsequent delivery, not proven by this change.
