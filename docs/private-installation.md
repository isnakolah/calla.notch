# Private installation on another Mac

## User intent

Make this customized Boring Notch easy to install on another Mac that has no
development tools installed. One guided setup should explain and prepare the
required tools, accounts, models, and permissions, then make the app and Tangit
ready to launch. Put a transferable copy in Downloads.

Bundle Tangit and the private components that cannot be fetched from public
downloads, together with Codex, AGY, and the runtimes needed to launch them.
Use device-code login for Tangit's Codex accounts. Prevent missing AGY
credentials or an internet outage from repeatedly opening the browser.

The final installation flow should expose only **Boring Notch.app** for the
unsigned-app approval in Privacy & Security. The earlier command launchers were
being rejected, and the transient welcome disappeared after approval. Replace
that experience with a persistent setup window inside the app. Normal macOS
privacy permissions remain separate from that app-opening approval.

## What was implemented

- A single-app disk image with the installer, private components, and provider
  tools inside **Boring Notch.app**. There are no `.command` launchers or
  separate setup applications.
- A native setup window with nine steps, live per-step activity, determinate
  download progress, elapsed time, prompts, errors, retry/resume controls, and
  actions to open Boring Notch or Tangit. Private builds suppress the old
  transient notch welcome.
- Installation through the app's existing XPC service while retaining the
  main app's sandbox. Setup installs into `/Applications/boringNotch.app` and
  preserves existing user data during repair or replacement.
- Tangit built from the sibling source tree, automatic discovery of bundled
  providers, and Codex device authentication by default.
- AGY checks for credentials and connectivity before background work or login.
  Explicit login retries, credential preservation on network failures, and
  sign-in URL deduplication address the repeated-browser problem.
- Private package validation, stable local signing, checksums, release
  manifests, and an explicit update/repair path for subsequent private builds.

### What is included and what setup downloads

| Component | Delivery |
| --- | --- |
| Customized Boring Notch, Calla engine, capture hosts, Tutor host, frameworks, setup helpers, and private Gateway payload | Bundled in the app |
| Tangit `0.1.0-private+b1335a0a24df` | Compiled from the local Tangit working tree and bundled |
| Codex CLI `0.162.1`, Claude Code `2.1.290`, AGY `1.3.5` | Bundled native tools with required resources and licenses |
| Small English live speech model, about 488 MB | Reused if already in place (Components, a carried `Boring Notch Components` folder, Mila); otherwise downloaded |
| Optional archive speech models, about 2.8 GB | Same, if selected |
| Apple Command Line Tools for Git | Installed if Git is missing; full Xcode is unnecessary |
| Tailscale | Downloaded if the optional existing Gateway is enabled |
| Accounts, passwords, API keys, OAuth tokens, SSH private keys, and signing private key | Not transferred; the recipient supplies their own accounts |

The private Gateway payload supports the existing remote server. Setup does
not provision a new local Gateway or OpenClaw installation.

### One place for tools and models

Everything setup installs outside the app lives in
`~/Library/Application Support/boringNotch/Components`:

```
Components/
  agy/<version>/agy            agy/current -> <version>
  codex/<version>/bin/codex    codex/current -> <version>
  claude/<version>/bin/claude  claude/current -> <version>
  models/whisper-small-en.bin, whisper-large-v3-turbo.bin, …-encoder.mlmodelc
  downloads/                   partial and cached downloads
```

`Managed/agy` and `Calla/copilot/models`, where earlier builds kept these, are
moved into Components on the first run and replaced with links, so the engine
and the call host keep finding them without changes.

For every tool and model, setup uses the first of these that checks out, and
only then downloads:

1. already in Components (models verified by SHA-256, cached in a
   `.<file>.verified` sidecar so a resume does not re-read gigabytes);
2. a `Boring Notch Components` folder beside the disk image, in Downloads,
   on the Desktop, or at the top of any mounted drive;
3. the copy bundled in the package (tools);
4. the same version elsewhere on the Mac (`~/.local/bin`, Homebrew,
   `~/.claude/local` for single-binary tools; Mila's models by size and
   checksum);
5. a download with byte progress, speed and time left, resumed with HTTP
   range requests after an interruption.

`boring-notch export-components [folder]` writes this Mac's speech models to
a `Boring Notch Components` folder (default: Downloads; hard links when on the
same disk). `boring-notch components [--archive]` installs or checks
everything without the rest of setup.

### Unsigned build, least hassle

The package is signed with a local identity, not notarized. Files copied from
a USB or external drive carry no quarantine flag, so macOS asks nothing.
Files from AirDrop, Messages or a browser are flagged: either approve once in
Privacy & Security → Open Anyway, or run `xattr -c` on the `.dmg` before
mounting it (the mounted contents inherit the image's flag). Setup clears the
flag from the installed app and from everything in Components.

### Implementation locations

| Area | Main files |
| --- | --- |
| Packaging, tool pinning, and portable binary checks | `scripts/package-private.sh`, `scripts/prepare-tangit.py`, `Distribution/dependencies.json`, `scripts/verification/verify_private_package.py` |
| In-app setup window and private first launch | `Distribution/Sources/BoringNotchSetupUI/SetupWindowController.swift`, `boringNotch/PrivateSetup.swift`, `boringNotch/boringNotchApp.swift`, `boringNotch/BoringViewCoordinator.swift` |
| Guided installation, app bridge, and Terminal launch | `Distribution/Sources/BoringNotchSetup/`, `Distribution/Sources/DistributionCore/SetupSessionHost.swift`, `Distribution/Sources/DistributionCore/TerminalLauncher.swift` |
| Validated app replacement and repair | `Distribution/Sources/DistributionCore/PackageInstaller.swift` |
| XPC transport and AGY login/browser handling | `BoringCallaEngine/BoringCallaEngine.swift`, `boringNotch/components/Calla/CallaEngineClient.swift` |
| AGY background credential/connectivity checks | `Intelligence/Sources/IntelligenceProviders/AgyConnectivity.swift`, `AgyEnvironment.swift`, `AgyHost.swift`, `AgyTransport.swift`, `BoringNotchXPCHelper/UsageProbes/AGYUsageProbe.swift` |
| Tangit device login and bundled provider discovery, in sibling `../tangit` | `internal/provider/provider.go`, `internal/app/profiles.go`, `internal/app/bundled_providers.go`, `internal/app/setup_quick.go`, `internal/app/app.go`, `internal/app/types.go` |

## Fresh-Mac fixes (2026-10-15)

Reported on the receiving Mac: Gatekeeper asked again after installation, the
setup felt stuck during long steps, and Home showed only Now Playing.

| Problem | Cause | Fix |
| --- | --- | --- |
| Repeated Open Anyway prompts | `ditto` copied the disk image's quarantine flag onto the installed app and every nested helper and provider | The install transaction clears `com.apple.quarantine` on the verified staged copy; repair clears it on existing installs; the managed AGY copy is cleared too |
| Two notches, prompts split between two apps | The disk-image copy ran the full app beside the installed one, and permission, sign-in and Terminal prompts came from whichever copy asked | The disk-image copy is setup-only (no notch, menu bar item or services). After installing it hands off: it quits and the installed app reopens setup with `--continue-setup` |
| Long silent waits | Only step titles were structured; model download output went to the hidden log | `activity` and `progress` events; per-percent model download lines become a progress bar; the meeting test shows a live countdown |
| Resume repeated finished work | Every step re-ran; AGY login was forced each time | Steps check before acting: a working sign-in is verified, not redone; granted permissions are not re-requested; answered questions are not asked again. Check & repair asks everything again |
| Tangit needed Automation approval | Terminal was driven through AppleScript | A private launcher opened with `open -a Terminal`; AppleScript remains the fallback |
| Home showed only Now Playing | `showCalendar` defaults off and private builds skip the onboarding that turns it on | Setup turns the calendar on and requests calendar access |

The same round removed Tutor from the app, the engine and the package (no
`CallaTutorHost`, overlay helper, course/feedback relays or Tutor settings),
re-anchored engine readiness on the engine itself rather than the Tutor host
socket, and added team-ceremony call personas grouped as team rituals,
engineering and conversations. The `Tutor/` source tree remains because the
optional Gateway release is still built from `Tutor/Gateway`; the Gateway
health check now requires only the Gateway process.

## Delivered package and verification

Documented delivery: **2.7.3 (284)**, copied to Downloads on **2026-10-15**.

- DMG: `/Users/isnakolah/Downloads/boringNotch-private-arm64-2.7.3-284.dmg`
- Size: 349,082,699 bytes, approximately 333 MiB.
- Checksum and manifest: adjacent `.dmg.sha256` and `.manifest.json` files.
- Build output and recorded evidence: `build/private/`, including
  `verification-284.json`.

SHA-256:

```text
428657bc0a115eae9f7a609375764432433cdab4ebe65bbb7425d3c51daa846b
```

Completed checks recorded for this delivery:

- The mounted disk image contained one visible item, **Boring Notch.app**, and
  no `.command` files inside the app.
- Package validation checked required resources and nested code signatures.
  All 52 Mach-O files supported arm64, met the macOS 15 requirement, and linked
  only to system or bundled libraries.
- Bundled Tangit, Codex, Claude, and AGY reported their versions with an
  isolated home and a minimal system PATH. Tangit's doctor found its bundled
  Codex and Claude; its empty-profile warning was expected before setup.
- The build 284 setup window was visually inspected: it displayed **Begin
  setup** and all nine steps and remained open. On build 282, the integrated
  setup reached the real installation confirmation through XPC; declining
  kept the window open with **Resume setup**.
- The Downloads copy matched the source package checksum. The existing
  installed app on the development Mac was not replaced during this check.

The package uses **Calla Local Signing** and is not Apple-notarized. The
single-app approval flow has not been exercised on a separate clean Mac, so
an exact Gatekeeper prompt count is not proven. Full fresh installation,
privacy approvals, live account authentication, audio capture, and AGY offline
recovery with a real account still need acceptance on the receiving Mac.
The AGY fix is implemented and built; these package checks do not establish
end-to-end offline behavior. No new test suite run is claimed by this record.

## Building another package

Build on this development Mac:

```sh
scripts/package-private.sh
```

The command produces a DMG, SHA-256 checksum, and release manifest in
`build/private/`. It chooses the source version and advances a locally recorded
build number. For an explicit release:

```sh
scripts/package-private.sh --version 2.7.3 --build 285
```

The build needs Go 1.26+ and the Tangit source at ../tangit (override with
--tangit-source DIRECTORY), Xcode, the existing `Calla Local Signing` identity, Python 3,
and the Tutor pack build dependencies used by the normal app build. It never
installs the result or updates the Gateway. Keep the signing identity and its
private key safe on the build machine: future packages must use the same
identity to preserve macOS permissions. Neither key nor account credentials
are included in the DMG.

## On the receiving Mac

1. Copy the DMG, and any `Boring Notch Components` folder, from a USB drive
   (no macOS approval needed), or download it. Open it, and open
   **Boring Notch.app**.
   Choose **Begin setup**. Its native window shows the actual installer prompts
   and stays open while you approve permissions.
2. If macOS blocks the app, attempt to open it once, then choose
   **System Settings → Privacy & Security → Open Anyway** for Boring Notch.
   Reopen Boring Notch.app if macOS does not bring it back automatically.
3. Follow the numbered setup: application, managed AGY, meeting settings,
   Google sign-in, speech models, permissions, optional Gateway, meeting test,
   and Tangit profile setup. Tangit, standalone Codex 0.162.1, Claude 2.1.290,
   and AGY 1.3.5 are already bundled in the DMG.

The receiving machine needs an Apple Silicon processor, macOS 15 or later,
internet, your Google account, and administrator access if needed for
Applications or Tailscale installation. No repository, compiler, Homebrew,
Python, Node, or Go is needed on the receiving Mac. If Git is missing, setup
opens Apple's Command Line Tools installer and waits for its completion.
The full Xcode app is unnecessary. Allow at least 3 GB free when no speech
model is already in place, plus about 4 GB for the optional archive models;
Apple's tool download requires internet.

The bundled MediaRemoteAdapter framework requires macOS 15, even though the
upstream README advertises macOS 14. This private package enforces its actual
dependency minimum and opens Software Update on older Macs.

Live speech uses Small English (488 MB). Archive transcription is optional
and adds about 2.8 GB of downloads unless a carried folder has it; setup
checks for 4 GB of free workspace before downloading it. Transcription stays on the Mac. AGY sends selected
transcripts and context to remote model services using your account and quota.

Permissions are requested through the installed app and its capture hosts,
rather than Terminal. Approve microphone and Screen & System Audio Recording
for the app/host macOS identifies. Restart the app if macOS asks you to.
Calendar, reminders, camera, music control, accessibility and Full Disk Access
are feature-specific; use **Settings → Privacy & Permissions** to
enable the ones you need. Full Disk Access is unnecessary for meetings.

The meeting test requires a sentence spoken into the mic and a short spoken
clip played in Safari or another app. It verifies that *both* sources produced
transcript turns and checks an AI response. The test call is saved in History,
where you can delete it. Capture stops automatically if setup is interrupted.

The disk image contains one application: **Boring Notch.app**. Setup is a
persistent native window inside that application. There is no separate installer
application or .command launcher to approve in Gatekeeper. The private app retains
its sandbox; installation runs through its existing bundled XPC service and native
helper. After the staged copy's signature verifies, setup clears the disk
image's quarantine flag from that copy only, so its nested helpers and bundled
providers are not each re-assessed by Gatekeeper. No system security policy is
changed. Microphone, audio capture and optional integrations still require their
normal macOS privacy approvals. Tangit opens Terminal for its interactive profile
wizard; macOS may ask for Terminal automation permission for that action.

Private builds suppress the transient notch welcome. Native prompts are explicit
structured events, and progress and errors remain visible. Double-click the app
or use Setup, Repair & Updates to reopen setup. Once finished, choose Open Boring
Notch to switch from the mounted image to the installed copy.

## Tangit and provider login

Tangit's native executable is compiled from the local working tree, including
its device-login change. The manifest records its source revision and a hash
of Go build inputs. Provider downloads are pinned in Distribution/dependencies.json,
verified before packaging, and retain their original code signatures and
runtime resources. These native CLIs do not require Go or Node to launch on
the receiving Mac.

Tangit finds providers in the app's `Contents/Resources/Tangit/Providers`
directory even with a minimal PATH.
Setup offers profile creation and authentication, then a direct launch. Later,
use `tangit`, `boring-notch tangit`, or the setup window’s **Open Tangit** button. The command
wrapper preserves unrelated existing installations; the latter two options
always open this package's copy. Existing profiles and credentials are retained.

All Tangit Codex login entrypoints default to `codex login --device-auth`.
Open the displayed link and enter its device code. Enable device code login
in ChatGPT account security or workspace permissions if the provider requests it.
Explicit provider login flags still pass through. Claude has no equivalent
device-code flag; choose its supported browser login or an API key stored in
macOS Keychain. Accounts and quotas must be supplied on the receiving Mac.

AGY usage polling returns a sign-in-required state without starting AGY when
credentials are absent. Network checks return offline without opening OAuth.
Forced reauthentication preserves existing credentials on connection, quota,
or unknown failures, and only replaces them for explicit authentication
rejections. The app opens each published sign-in URL once across view rebuilds;
the engine no longer launches a duplicate browser. Reconnect and explicitly
retry after a connection failure.

Provider tool availability is checked during setup and by doctor. This does
not claim that a Tangit account can generate a response; sign in and use it
on the receiving Mac to confirm account access.

## Updates and repairs

Build the next package on the development Mac, transfer it, and open its
**Boring Notch.app** to run setup again. Existing preferences, accounts, calendars, history, encryption
keys and verified model downloads stay in place. A different signing identity
or an older private build is rejected. End Tangit and bundled provider sessions
before replacement. Updates also wait until you end active calls
and their finishing work. The replacement is staged and signature-verified
before the previous app is replaced; a failed replacement restores it.

From the app, choose **Setup, Repair & Updates…**. In a new Terminal window:

```sh
boring-notch doctor
boring-notch repair
boring-notch update /path/to/new-package.dmg
```

`doctor` checks signatures, the live model's checksum, credential presence,
the current host's permission receipt, and engine readiness without changing
settings. Online account validity and actual audio capture are checked by
setup's login/model catalog and meeting test. `repair` rechecks the actual
installation, replaces damaged live model downloads, and offers retries for
incomplete steps. Tools install from the bundled copies. Every download
(models, Tailscale, and tools if a bundle were missing) shows progress and
resumes after an interruption.

The first version uses transferred/downloaded packages for updates. It does
not use the original project's Sparkle feed: that would replace your custom
features with the upstream app. AGY is app-managed and version-pinned;
background AGY and bundled Claude updates are disabled in app-owned processes. To change its
version, update `Distribution/dependencies.json` from Google's official
manifest, validate compatibility, and build another package.

## Optional private Gateway

The wizard installs the official, checksum-verified, signed Tailscale package
if needed, opens its login, and uses Tailscale SSH to the existing Gateway.
Your Tailscale identity must be allowed to connect to the server's owner
account. Device or SSH approval is completed in Tailscale's browser flow.
Your existing Mac's SSH private keys are never transferred.

Skipping Gateway disables its polling, remote relays and meeting fallback.
Local AGY meetings remain usable. A Gateway outage is reported separately
from local readiness. OpenClaw and server-side Python stay on the Gateway.
Gateway release updates retain the existing explicit owner-triggered action.

## Validation commands for future changes

These are commands for a future verification pass, not a record of tests run
for the documentation update:

```sh
swift test --package-path Distribution
swift test --package-path Intelligence --filter 'AgyLocatorTests|AgyEnvironmentTests'
scripts/verification/verify_private_package.py /path/to/boringNotch.app
```

The package builder verifies nested signatures, required resources, arm64
slices, minimum OS versions and linked library paths, then verifies the DMG.
These checks do not establish that permissions and capture work on a fresh
Mac. Acceptance on an actual clean Mac or VM must cover first-open approval,
Google login and offline recovery without browser loops, Tangit device login,
both capture sources, transcription, AI response, optional
Tailscale login, repeat setup and upgrade preservation. The new setup window
can be inspected without beginning installation; this does not establish that
Gatekeeper, TCC and all account flows work on a clean Mac.
