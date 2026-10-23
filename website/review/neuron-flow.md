# Conversation → notch → neurons: local review

Implemented and reviewed locally on 23 October 2026. The intent is to make the
proof of concept visually understandable: see Calla in a meeting, follow a piece
of information into the brain, then explore the connected company knowledge.

## Implemented

- The actual native footage sits at the top edge of a neutral desktop meeting.
  Desktop selects `notch`; mobile selects `notch-mobile`. Both retain their native
  aspect ratios. The full 45-second recording loops after the final recap.
- One deterministic recording clock drives speaker capture, the native summary
  update, packet transfer, neuron formation and branch/link growth. Reconfirmation
  brightens existing knowledge; unresolved Finance knowledge is amber.
- The solid anatomical mesh is replaced by a sampled neural scaffold and growing
  cells. The licensed mesh remains an invisible, attributed positioning guide.
- One reusable fictional dataset supplies all views: 40 meaningful points and 59
  named, sourced relationships across three workstreams.
- The full-screen 3D explorer provides orbit/pan/zoom, cluster colours, search,
  type filtering, relationship inspection and source excerpts. Native citations
  return to the exact scripted turn and leave the recording paused.
- Materials and geometries are shared where practical; hidden views stop rendering,
  mobile/explorer rendering is capped at 30 FPS, and closed explorer resources
  and WebGL contexts are released.

## Verification

- Frontend: all 10 Node tests pass. These cover graph integrity, source references,
  all eight native capture/summary pairings, arrival before formation/linking,
  dependency resolution, deterministic seeking/replay and watch-progress tracking.
- API: all 12 existing tests pass, including signup, concurrency, privacy,
  reporting and auth. The storage-failure test deliberately logs an error and passes.
- Production Vite build passes. The shared Three.js chunk remains about 578 KB
  minified / 144 KB gzip and produces the existing 500 KB size advisory. Brain
  and explorer entry modules are split from the initial page.
- Chrome: verified the visible transfer at 6.3 seconds; pause freezes the sequence,
  backwards seeks restore state, and native citations return to their exact turn.
- Explorer: verified search, the six-person filter, empty results, reset,
  selection, source inspection, Escape dismissal and focus restoration. Opening
  pauses playback; closing resumes only if it had previously been playing.
- Responsive: reviewed at 1710×930, 1366×768, 390×844 and 320×640. Checked horizontal
  overflow, mobile native source selection and laptop scene/signup separation.
- Mobile story keeps the meeting, brain and controls in vertical reading order.
  Chapter selection follows the section entering the reading line, so the long
  opening scene does not disappear before its playback/signup controls.
- Reduced-motion emulation was recognised and suppressed travelling packets.
  Knowledge updates discretely; camera motion, pulses and interpolated growth
  are disabled.
- Deliberately lost WebGL contexts in both views. The brain switched to a static
  neural diagram; the explorer retained its searchable nodes and source details.
  Emulation and viewport overrides were cleared and pages reloaded afterward.
- No browser console errors were observed in the final preview.

## Review images

- `neuron-flow-desktop.jpg`: call → native notch → brain transfer.
- `neuron-graph-desktop.jpg`: the complete 3D sample company graph.
- `neuron-graph-mobile.jpg`: the 3D explorer on a narrow display.

The existing local server at http://127.0.0.1:4187 serves the rebuilt page. No
public deployment, native-app changes or live knowledge ingestion were performed.
Browser checks establish Chrome behavior; Safari/Firefox and a physical touch
screen were not separately acceptance-tested. The earlier evidence remains in
`verification.md`; its screenshots describe the previous design.
