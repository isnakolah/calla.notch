# Designs

Each folder is one design canvas: `canvas.json` lays out the artboards, and each
`*.dc.html` is one artboard (a self-contained HTML page). Open an artboard in a
browser to look at it; the interactive ones (`Main.dc.html`, `FloatContext.dc.html`)
need the canvas editor to run their scripts.

| Folder | What it covers | Status |
| --- | --- | --- |
| `notch-redesign/` | The Notch Glass vocabulary and the first pass at every tab | Earlier work |
| `live-coding/` | Live coding interview surfaces | Earlier work |
| `call-redesign/` | The whole call: approach, hover peek, closed notch, get ready, live states, recap, spin out, notes for Calla, settings | Implemented, see below |
| `zen-mode/` | Zen during a call, the panel on click, and the floating window | Implemented, see below |
| `call-tab/` | The call tab at rest at the notch's normal 512×168, call types ranked by likelihood, the in-notch picker, today's calls | Implemented, see below |

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
- **Call tab** (`call-tab/Tab*`): four lines at 512×168, the three most likely
  types on the rail, no readiness grid, the headline and button taken by
  whatever is missing.
- **Call types ranked** (`call-tab/Picker*`, the purple note): every type ordered
  by `CallTypeRanker` with a band and a reason; Start asks only when Calla is not
  sure; the picker and today's calls open in the notch, never as a dialog.
  `call-tab/TabToday` is the old tab, kept for comparison.
- **Settings**: where the call panel lives, the meeting pop-open switch, zen
  settings, Knowledge renamed Notes for Calla, History renamed Past calls.

## Also implemented

- **Recap after a call** (`call-redesign/Recap`): once the write-up is done the
  notch opens on it: what was decided, what is still open, and the to-dos, which
  can go to Reminders; copy a follow-up email; open it in Past calls. Settings ›
  Calls › "Show the recap when a call ends". Owners and due dates are shown only
  when the recap's own words carry them.
- **Notes for Calla** (`KnowledgeDrop`, `KnowledgeInCall`, `SettingsNotes`): a
  dropped file is read at once and asks one question (just the next call, every
  time it repeats, or every call). Mid-call, the paperclip in the panel's band
  lists what Calla is using with a switch for each, for this call only (a new
  `knowledge` host command; the frozen pack is untouched). The Notes page leads
  with Every call, Meetings that repeat, Coming up and "Carry recaps forward".
- **One Calls page** (`SettingsCalls`): before, during and after a call, where
  answers come from, kinds of call, and Advanced. Models and Prompts are reached
  from it and are no longer sidebar rows.
- **Stay in zen while sharing** (`ZenSettings`): while a call app shows its
  sharing bar, hovering does not open the panel; a click on zen does.
- **Always hidden from sharing** (`InCallShare`): from a call starting until its
  recap is put away, the notch and the floating window are out of every share
  and recording. "Hide from screen recording" now only decides the notch at rest.

## Deliberately not implemented

- Every answer surface (`LiveAnswer`, `LiveAsk`, `FloatingAnswer`, the answer
  states in `Hover` and `InCall`): answers are switched off in the app
  (`CallaCopilotLiveView.answersRetired`). They become live if that is turned back on.
- "Used in N calls" beside a note, and "used in 2 answers" in the in-call list:
  the store does not count uses, and answers are off.
- `call-redesign/Prep`'s get-ready panel: `call-tab/` replaced it at the notch's
  real size.
