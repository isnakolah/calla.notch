# Live Coding reasoning-first flow — 2026-09-05

Implemented in the existing dirty checkout at `/Users/isnakolah/dev/boring.notch`. Existing changes were preserved. No commit or push was made because the feature's starting implementation was already untracked alongside extensive unrelated work. A source baseline was captured at `/tmp/coding-flow-baseline` before editing.

Generic Code and Wave now share a conversation state and reducer. Clarifications distinguish a displayed suggestion from an actually spoken question. Facts retain their speaker and transcript anchors, separating interviewer requirements, candidate choices and assumptions. Completed speech reaches dialogue interpretation before narration suppression. One utterance can cover multiple reasoning steps; the candidate does not have to recite a fixed script.

Implementation requires a completed candidate cue or the global Next action after reasoning. Authorization covers the current stage and its pending behaviors. A cue naming duplicates or empty input covers that case specifically. Held cards stay fixed. New requirements revoke dependent publication authority and invalidate preparation. Older snapshots decode without the new optional fields, and resume preserves context while dropping implementation authorization.

A read-only conversation worker interprets evidence. Separate planner/coder jobs use private proposal copies and prepare up to three pending behaviors. The publication gate prevents private code from entering snapshots, move events or the reader before authorization. Saved-source assessment supports alternative implementations; a proposed block and a passing private experiment cannot complete interview work. Explicit Run checks an exact private copy of saved source and retains the separate execution cue boundary.

Code owns automatic question admission. Call retains answer generation, knowledge, transcript/history and recap work. Coordinated requests preserve question IDs and transcript anchors. Candidate clarification questions wait for interviewer replies. Independent interview questions can reach Call immediately; duplicate requests retain one owner. Call answer surfaces remain explanatory, and stale Code-context answers are discarded.

Ask arms the next completed candidate utterance; pressing it again cancels. Explain more submits the displayed item immediately. These handlers do not activate the app or open text input. The global Explain action can queue an explanation while Hold keeps the displayed card fixed. The reader includes Why, Limitation and Pending details; Say next stays visible outside the scroll area. Existing sizing/model preferences and global controls remain in use.

Two runtime defects surfaced during verification and were fixed: source-revision hashes depended on JSON key order, and noninteractive AGY denied private edits without a write-file allow-rule. Revisions now use sorted keys and root-independent internal-symlink identities. Coder permissions name only the private work directory, including its canonical path. A kernel sandbox independently denies writes outside the worker's private directories; conversation workers cannot write project or context files. No command allow-rule or permission-bypass flag was added. Snapshot cleanup uses normal owner permissions while the sandbox protects context.

Verification results are separated by what was actually exercised:

| Check | Result | Boundary |
| --- | --- | --- |
| CallaContracts | 71 tests, zero failures | Optional archive fields, stage publication, question IDs/anchors and existing contracts |
| Intelligence, clean build | 402 tests, zero failures; 5 opt-in tests skipped | Dialogue/evidence reducer, cue scope, multi-step reasoning, correction, partial/short answers, source evidence, queue/revision rules and existing suites |
| CallaCallHost, clean build | 154 tests, zero failures; 1 skipped | Automatic question ownership, Gateway push suppression, stale generation handling and existing host tests |
| Root engine validation, clean build | 157 tests, zero failures; 1 live test skipped | Actual CodingSessionController is compiled and tested, both profiles, Hold/Ask/Explain, failure, saved alternatives, encrypted resume with isolated test keys, transcript sequence reset, lifecycle fences, source revision and OS write boundaries |
| Authenticated AGY live check | Passed separately, 86.8 seconds for the entire fixture | Real dialogue worker, real private coder, semantic example recognition, unchanged source, private edit and pre-cue publication gate |
| Provider-only warm response | 3,830 ms | One sample; excludes ASR, transport to the installed app and display |
| Provider-only response with private coder active | 2,618 ms | One sample; not a percentile or installed speech-to-visible measurement |
| Native reader fixture | Passed | Production reader component; synthetic controls/content. Exact independent scroll restoration and overlapping shortcut scroll checks passed |
| Xcode Release | BUILD SUCCEEDED | App, engine and embedded runtime build |
| Installed Release | Deployed and launched through `scripts/deploy.sh --config Release` | Installer verified embedded helpers/runtime; application process running. Deep strict signature verification passed and installed app/engine hashes matched the Release products |
| Installed mock with both audio sources | **Not completed — blocked** | Computer Use returned `timeoutReached` for the installed app and `cgWindowNotFound` for the editor and the newly installed app |

The installed audio capture path, editor-focus preservation, actual shortcut interaction, compact prompt readability in the notch, and speech-to-visible latency under load are therefore still unverified. Component rendering and the real-provider harness do not establish those results. No recording was started through an unseen UI.

Reproduce the checks from the repository root:

```sh
swift test --package-path CallaContracts
swift test --package-path Intelligence --scratch-path /tmp/coding-flow-intelligence-build
swift test --package-path CallaCallHost --scratch-path /tmp/coding-flow-callhost-build
swift test --scratch-path /tmp/coding-flow-engine-build
CODING_DIALOGUE_LIVE=1 swift test --scratch-path /tmp/coding-flow-engine-build --filter CodingDialogueLiveTests
python3 scripts/verification/render_coding_viewport.py --fixture scripts/verification/coding_dialogue_viewport_fixture.swift --output /tmp/coding-dialogue-layout
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release build
```

The live fixture uses the existing configured default model family and authenticated AGY installation on synthetic interview material. It consumes provider quota. Its normal test-suite run is opt-in and skipped.

Review groups:

1. `CodingInterviewFlowState.swift`, `CodingInterviewFlow.swift`, optional contracts and dialogue tests.
2. `CodingSessionController.swift`, the controller integration harness, cue/progression/publication and saved-source handling.
3. `CodingAgyWorker.swift`, `WaveWorkerPool.swift`, workspace prompts, scoped edit permissions and OS boundary tests.
4. `CopilotAdvisor.swift`, the coordinated Call command path and question-admission tests.
5. `LiveCodingViewport`, reader fixture, Release installation and this evidence record.

Render examples are [compact reasoning](compact-reasoning.png) and [expanded code](expanded-code.png). At small saved heights, details require scrolling; the next spoken cue remains visible.
