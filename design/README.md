# Designs

Each folder is one design canvas: `canvas.json` lays out the artboards, and each
`*.dc.html` is one artboard (a self-contained HTML page). Open an artboard in a
browser to look at it; the interactive ones (`Main.dc.html`, `FloatContext.dc.html`)
need the canvas editor to run their scripts.

| Folder | What it covers | Status |
| --- | --- | --- |
| `notch-redesign/` | The Notch Glass vocabulary and the first pass at every tab | Earlier work |
| `live-coding/` | Live coding interview surfaces | Earlier work |
| `call-redesign/` | The whole call: approach, hover peek, closed notch, get ready, live states, recap, spin out, notes for Calla, settings | Partly implemented, see below |
| `zen-mode/` | Zen during a call, the panel on click, and the floating window | Implemented, see below |

Where the two call canvases disagree, `zen-mode/` is newer and wins: it replaces
`call-redesign/`'s live panel boards (`LiveListening`, `LiveTrouble`) and its
floating boards (`FloatingLive`, `FloatingMini`).

## What is implemented

Checked against the code by the `verify-call-design` skill in
`.claude/skills/verify-call-design/SKILL.md`. Run it after any change to the call
surfaces.

- **Closed notch during a call** (`call-redesign/ClosedStates`): words, not glyphs.
- **Hover peek** (`call-redesign/Hover`): hovering a call or a meeting grows one
  line; a click opens.
- **Meeting approach** (`call-redesign/Approach`): T−15 grey, T−2 Get ready, T−0
  Join, T+3 orange, quiet after ten minutes.
- **Spin out** (`call-redesign/SpinOut`, `zen-mode/Float*`): the floating window,
  its strip, docking at the top edge, ⌥⌘F.
- **Zen** (`zen-mode/ZenStates`, `ZenLevels`, `ZenSettings`).
- **Panel on click** (`zen-mode/PanelCompact`, `PanelFull`, `PanelTrouble`).
- **Settings**: where the call panel lives, the meeting pop-open switch, zen
  settings, Knowledge renamed Notes for Calla, History renamed Past calls.

## Deliberately not implemented

- Every answer surface (`LiveAnswer`, `LiveAsk`, `FloatingAnswer`, the answer
  states in `Hover` and `InCall`): answers are switched off in the app
  (`CallaCopilotLiveView.answersRetired`). They become live if that is turned back on.

## Not implemented yet

- `call-redesign/Recap`: decisions and to-dos with owners after a call.
- `call-redesign/KnowledgeDrop`, `KnowledgeInCall`, `SettingsNotes`: the
  one-question notes flow, and switching notes off for one call.
- `call-redesign/SettingsCalls`: merging the six call settings pages into one.
- `call-redesign/Prep`: the get-ready panel without boxes.
- `zen-mode/ZenSettings` "Stay in zen while I share my screen": needs share detection.
- `call-redesign/InCallShare`: hidden from sharing *always*. The app keeps it as
  the user's `hideFromScreenRecording` choice, off by default.
