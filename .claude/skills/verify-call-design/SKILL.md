---
name: verify-call-design
description: Check that the call redesign in design/call-redesign and design/zen-mode is implemented correctly in the app — closed notch wording, hover peek, meeting approach, zen, the panel on click, the floating window and their settings. Use after building or changing anything in the call surfaces, or when asked whether a design has been implemented.
---

# Verify the call redesign

You are checking the macOS app against two design canvases in this repo:

- `design/zen-mode/`: newer. Zen, the panel on click, the floating window.
- `design/call-redesign/`: approach, hover, closed notch, spin out, settings.

`design/README.md` lists what is meant to be implemented and what is
deliberately left out. Do not report a deliberately-left-out item as a failure.

Work through the four stages in order and stop to report if a stage fails.

## 1. It builds and the logic tests pass

```sh
xcodebuild -project callaNotch.xcodeproj -scheme callaNotch -configuration Debug build
swift test --filter "ClosedCallLineTests|MeetingApproachTests|MeetingClosedActivityTests|FloatingPanelTests|ZenContentTests|ClosedNotchArbiterTests"
```

The rules the designs depend on are pure and tested in
`CallaEngineTests/Tests/CallSurfaceTests.swift`. If a test fails, the design
rule in its name is broken: say which, and quote the assertion.

## 2. The code matches each design decision

Read each file named below and confirm the rule. Note the line you checked.

| Design (artboard) | Rule | Where |
| --- | --- | --- |
| `call-redesign/ClosedStates` | Closed notch during a call shows a word left of the camera ("Listening", "Only you", "Catching up") and the clock or "Floating" right | `CallaCopilotPresentation.closedLine`, `CopilotNotchBadge.callBody` |
| `call-redesign/Hover` | Hovering a call or meeting peeks one line after 0.15 s and folds 0.4 s after leaving; it never opens the panel; a click does | `NotchPeekPolicy`, `CopilotNotchBadge.hover`, `ContentView.closedNotchPeeks`, `handleHover`, `openFromClosed` |
| `call-redesign/Approach` | Grey time from 15 min out, "Get ready" from 2 min, "Join" at the start, orange "Started N min ago" from 3 min, nothing after 10 min or once joined | `MeetingApproach.phase`, `MeetingApproach.line`, `MeetingApproachBadge` |
| `call-redesign/Approach` | Join opens the meeting through the get-ready panel, which chooses the call type, VPN and notes | `MeetingApproachWatch.requestJoin`, `CallaCallPreflightView` `.onReceive(meetingWatch.$joinRequest)` |
| `call-redesign/Approach` | The notch does not pop open at T−2 unless "Open the notch when a meeting is about to start" is on | `ContentView` `.callaMeetingWantsNotch` guard on `.callaMeetingOpensNotch` |
| `zen-mode/ZenStates` | Zen always shows something: needs-you, then the newest point plus the ones before, or before any point the meeting and "Hearing both sides…". Never transcript lines | `CallaZen.content`, `CallaZenReading`, `CallaCopilotAmbientView.zenView` |
| `zen-mode/ZenStates` | No labels in zen; the band word is Listening / New (6 s) / Catching up / Only you | `CallaAmbientWings`, `CallaZenState.note`, `CallaZen.highlightSeconds` |
| `zen-mode/ZenLevels` | Just the dot shows nothing under the camera; Brief the newest point and the ones before; More adds "Still open" | `CallaZen.Level`, `CallaZen.content` |
| `zen-mode/ZenSettings` | Rest in zen, Zen shows, Back to zen after, Highlight new points | `CopilotPane.duringCall`; keys `callaCopilotAmbient`, `callaZenLevel`, `callaZenReturnDelay`, `callaZenHighlight` |
| `zen-mode/PanelCompact` | Compact is Calla's points (newest large, earlier marked settled or still open), no transcript, End at the foot | `CallaCopilotLiveView.compactPanel`, `pointsFeed`, `panelFooter` |
| `zen-mode/PanelFull` | Full keeps the account beside the transcript, End at the foot, not in the band | `CallaCopilotLiveView` body full branch, `CallaCopilotLiveHeader.trailing` |
| `zen-mode/PanelTrouble` | Only hearing you is plain type and one "Allow call audio" button, no boxed banner | `halfDeafPlain` |
| `call-redesign/SpinOut` | Float from the band button, ⌥⌘F, or the setting; back by the dock button, clicking the closed notch, or dropping the window at the top near the camera | `CopilotLiveSession.spinOut/dock`, `copilotToggleFloat`, `FloatingPanelGeometry.shouldDock`, `CallaFloatingCallWindow.settle` |
| `zen-mode/FloatFull` | Glass window: meeting name and state on top, where it stands as the hero, settled and still open, live transcript with initials and the speaker ringed, End at the foot | `CallaFloatingCallView` |
| `zen-mode/FloatStrip` | The minus button shrinks it to a one-line strip that keeps its top edge; the chevron grows it back | `CallaFloatingCallState.strip`, `CallaFloatingCallWindow.applyStrip` |
| `call-redesign/SpinOut` | The window is always on top, on every Space including full screen, follows the hide-from-screen-recording setting, and remembers its place per display | `CallaFloatingCallPanel`, `applySharingType`, `callaFloatingFrames` |
| `call-redesign/SettingsCalls` | "Where the call panel lives": In the notch / Floating / Where I left it | `CopilotPane`, `CallPanelHome`, `CopilotLiveSession.apply(running:)` |

## 3. It behaves like the design in the running app

Deploy with `scripts/deploy.sh` (or run the Debug build), then do each step and
compare with the artboard named. If you can take screenshots, take one per step
and set it beside the artboard.

1. With no call, open a calendar meeting with a call link that starts in 14 minutes
   (Settings › Calendar must have the account enabled for calls). The closed notch
   shows its short title and time in grey (`Approach`, row T−15).
2. Hover the closed notch: one line grows under it, nothing opens, the app you were
   in keeps focus. Move away: it folds back (`Hover`, frames 2 and 4).
3. Start a call with ⌥⌘C. With the pointer away, the notch rests in zen: the dot and
   "Listening" left, the clock right, and before any summary the meeting name and
   "Hearing both sides…" under it (`ZenStates`, rows 4 and 5). No transcript lines.
4. Wait for the first summary: the band word says "New" for about six seconds, then
   "Listening"; the newest point shows with the earlier ones on one line (`ZenStates`, rows 2 and 3).
5. Change Settings › Calls › Zen shows to Just the dot and More; check each against `ZenLevels`.
6. Hover the notch: the compact panel shows the points feed, no transcript, End at the
   foot, screenshot in the band (`PanelCompact`). Expand: the full panel shows the
   transcript column (`PanelFull`). Leave: back to zen after the "Back to zen after" delay.
7. Press ⌥⌘F: the floating window appears top right, glass, meeting name on top
   (`FloatFull`). The closed notch says "Floating". Press minus: it becomes a strip
   (`FloatStrip`). Drag the window to the top near the camera: the border turns blue,
   the header says "Let go to put it back in the notch", and letting go docks it.
8. Turn off Screen Recording for the call host (or test with mic only): the band says
   "Only you" in orange and "Allow call audio" appears in zen, the panel and the
   floating window (`ZenStates` row 1, `PanelTrouble`, `FloatTrouble`).
9. With "Hide from screen recording" on, share your screen in a call app: neither the
   notch nor the floating window appears in what others see (`InCallShare`).

## 4. Report

Write the report to the user in this shape, one line per row of the table in
stage 2 and per step in stage 3:

- **Matches**: rule, and the file and line you checked or what you saw.
- **Differs**: what the design shows, what the app does, and the smallest fix.
- **Could not check**: why (no calendar meeting, no Screen Recording toggle, no screenshots).

End with the build and test result, and say plainly whether the app was actually
run or only the code was read. Do not fix anything unless the user asks; list the
fixes instead.
