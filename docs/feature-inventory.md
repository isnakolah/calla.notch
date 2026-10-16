# Feature inventory — before the strip-down

A record of everything the app contained on 2026-10-16, taken on branch
`snapshot/pre-strip-down` before features were removed. To bring a feature
back, start from that branch.

## Notch surfaces

| Feature | Where | What it does |
| --- | --- | --- |
| Home tab | `ContentView`, `components/Calendar`, `components/Music` | Now Playing plus upcoming calendar events |
| Media / music | `components/Music`, `managers/MusicManager`, `mediaremote-adapter` | Now Playing, music live activity, visualizer, media controls, media slots |
| Calendar | `components/Calendar`, Settings › Calendar | Upcoming events, calendar sources; also feeds meeting detection |
| Shelf | `components/Shelf` | Drop files into the notch; AirDrop, LocalSend, KDE Connect, Quick Share |
| Webcam mirror | `components/Webcam`, Settings › Appearance › Camera | Camera preview in the notch |
| Pomodoro | `components/Pomodoro` | Focus timer tab, planner, closed-notch badge |
| Usage monitor | `components/UsageMonitor`, `BoringNotchXPCHelper/UsageProbes` | Claude / Codex / AGY allowance, Tangit profiles, closed-notch badges |
| Battery indicator | `components/Live activities/BoringBattery.swift`, Settings › System › Battery | Charging and low-battery notifications |
| Volume / brightness HUD | `InlineHUD`, `OpenNotchHUD`, `SystemEventIndicatorModifier`, Settings › System › HUD | Replaces the system HUDs |
| Download indicator | `components/Live activities/DownloadView.swift` | Downloads in progress |
| Face animation | `components/AnimatedFace.swift` | Idle face in the closed notch |
| Hello animation, tips, What's New | `HelloAnimation`, `components/Tips`, `WhatsNewView` | First-run and update chrome |
| Onboarding | `components/Onboarding` | Public first-run flow (private builds use `PrivateSetup`) |
| Gestures, multi-display, notch sizing | Settings › General, Appearance › Notch size | Swipe to open/close, per-display, resize editor |

## Menu bar and system tools

| Feature | Where | What it does |
| --- | --- | --- |
| Ice | `boringNotch/Ice`, Settings › Ice | Menu bar extras organizer: sections, reveal gestures, search, spacing |
| Sweep | `SweepService/` (XPC), Settings › Sweep | Disk usage and safe cleanup |
| Sparkle updates | `updater/`, `CheckForUpdatesView` | App self-update |

## Call Copilot (Calla)

| Feature | Where | What it does |
| --- | --- | --- |
| Live call | `components/Calla/CallaCopilotLiveView.swift`, `CopilotLiveSession` | Zen / compact / full call panel: summary, answers, transcript |
| Call host | `CallaCallHost/` | Capture, VAD, Whisper transcription, advisor, recap |
| Engine | `BoringCallaEngine/` (XPC) | Owns the host, status, history, private setup |
| Local brain (agy) | `Intelligence/Sources/IntelligenceProviders/Agy*` | Antigravity CLI as the local model, Google sign-in |
| Gateway fallback | `Tutor/Gateway`, `Distribution/Sources/CallaGateway`, Settings › Copilot › Models | Remote OpenClaw Gateway when the local brain fails |
| Personas | `Intelligence/.../Prompts/live/personas` | Per-call persona shaping answers |
| Prompt editing | Settings › Copilot › Prompts | Edit copilot prompts |
| Quiz | `CallaQuiz*`, Settings › Copilot › Quiz | Reads a question off a window and answers it; encrypted key |
| Live coding (Code) | `CallaCoding*`, Settings › Copilot › Coding | Step-by-step coding-interview presentation |
| Wave interview | `WaveInterview.swift` | Wave interview profile and expanded layout |
| Pre-meeting pre-roll | `MeetingDetector`, engine `prewarming` | Warms the copilot before a scheduled meeting |
| Knowledge library | `CallaKnowledge*`, `NotchDropRouter`, Settings › Copilot › Knowledge | Documents attached to meetings as context |
| Screenshots as context | `ScreenSnapshot.swift`, camera button | Shared-screen screenshots read by the copilot |
| Speaker identification | `SpeakerPass`, `ArchiveDiarizer`, `VoiceprintMatcher` | Names and remembers voices after the call |
| Call history and recaps | Settings › Copilot › History / Call detail | Past calls, recap, transcript |
| Archive re-transcribe | `ArchiveTranscriber` | Cleaner transcript after the call |
| Backup | Settings › Copilot › Backup | Credential backup / restore for agy |
| Private distribution | `Distribution/`, `scripts/package-private.sh`, `PrivateSetup.swift` | Transferable installer with guided setup |

## Settings sections at snapshot time

General (General, Displays, Gestures, Advanced) · Appearance (Appearance,
Accent, Camera, Notch size) · Media (Media, Media slots) · Calendar (Calendar,
Sources) · System (System, Battery, HUD) · Shelf (Shelf, LocalSend, KDE
Connect) · Pomodoro · Call Copilot (Call, Models, Prompts, Knowledge, History,
Call detail, Quiz, Coding, Backup) · Ice · Sweep · Shortcuts · Privacy &
Permissions · About.

## Removal decisions (strip-down, 2026-10-16)

Removed on `feat/strip-down`:

- **Ice** — menu bar organizer, its Settings section and package target.
- **Sweep** — the SweepService XPC target, its Settings section, the Full Disk
  Access permission row, and its checks in `scripts/deploy.sh`.
- **Webcam mirror** — `WebcamManager`, the mirror header item, the camera
  onboarding step and the camera entitlement.
- **Battery indicator** — charging notifications, the battery header item and
  its Settings page.
- **Download indicator**, **face animation**, **hello animation**, **tips**,
  **What's New**, and the never-shipped custom visualizer page.
- **Live coding and the Wave interview** — app side: the Code mode, its notch
  surfaces, setup, Settings page, size profiles and shortcuts. The engine,
  contracts and Intelligence side are still present and are removed next.
- **Gateway fallback** — pending.

Settings went from thirteen sections to four — General, Notch, Calls, About —
each a single scroll with rarely-changed options folded under Advanced.

Kept: Music, Calendar, Shelf (LocalSend, KDE Connect), Pomodoro, AI usage,
volume/brightness HUD, the call copilot with Quiz, Knowledge, screenshots,
speaker identification, history, re-transcribe, personas, prompt editing,
onboarding and the Sparkle updater.
