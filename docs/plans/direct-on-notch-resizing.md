# Direct On-Notch Resizing

## Goal

Add Appearance > Notch Size editor that opens target notch, previews three
persisted size profiles, supports direct bottom-right resizing, and restores
prior notch state when editing ends.

## Profiles

- Normal: default `512 x 168`, bounds `512...900 x 168...560`.
- Call expanded: default `600 x 340`, bounds `460...900 x 240...560`.
- Call collapsed: default `512 x 200`, bounds `460...900 x 150...420`.

Normal applies to regular tabs, idle Call, sign-in, and pre-roll. Starting,
ending, and failed Call surfaces use Call collapsed. Active expanded/collapsed
Call surfaces use their matching profiles. Knowledge and drop surfaces apply
content minimums without changing saved Normal size.

## Editor

- Opening Appearance > Notch Size starts one shared `NotchResizeSession` on
  display containing Settings window.
- Target notch opens and remains pinned while editor is active.
- Detached bar below notch provides profile selection, dimensions, Reset, and
  Done.
- Bottom-right 28-point grip resizes around top-center anchor. Horizontal drag
  doubles pointer delta; vertical drag uses pointer delta directly.
- Drag updates persist immediately, clamp to profile and screen bounds, disable
  animation during movement, and settle on release.
- Normal previews regular tab content. Call profiles show inert sample content
  and never invoke capture or engine commands.
- Done, navigation away, Settings close, or target-display change restores safe
  state. Active Call always regains real current-layout panel.

## Interaction Boundaries

- Suppress hover auto-close, swipe gestures, file-drop routing, and root drag
  handling on target notch during editing.
- Report notch and detached bar as separate interactive regions so transparent
  gap remains click-through.
- Keep screen-sharing setting behavior unchanged.

## Proof

- Unit tests: bounds, screen clamp, centered drag, profile mapping, transient
  minimums, reset values, and restoration decision.
- Route/search checks for Appearance page and Call redirect.
- Swift tests, Release `xcodebuild`, `git diff --check`, graph refresh when tool
  exists, then signed installed-app cursor/click-through/visual acceptance.
