# Arrival and rehearsal

## Arrival

Prepare selects the project and reads it as it is. The supplied part-2 files are
placed in the project folder by hand, so there is no bundle to verify, no staged
merge, and no recovery snapshot to keep — and nothing that can diverge from what
the session actually runs against.

Prepare dependencies in the shadow copy. Run the conformance probe: every
documented fact in `spec.md` against the installed libraries, recorded as match
or difference in `library-probe.md`, and a map of the project's own modules and
symbols in `project-map.md`. Record exact commands, output, installed versions
and unresolved differences. Do not generate interview implementation during
preparation. Keep the context pack version, source revision and requirements
revision on every result.

Before the supplied files are in place, `sheet.formula` is simply not installed
and the probe says so. That is the expected state, not a failure.

## Rehearsal

Rehearsal acceptance requires a real installed two-hour flow, not an accelerated
unit test. Include supplied files appearing in the project folder mid-session, a
general interview question during coding, a manual follow-up, attached
knowledge, history, transcript, recap, and a changed requirement halfway through
sum. Inject worker exit, cancellation and selected-window loss without restarting
Call. Test partial saves, alternate implementations and unrelated edits.

Drills, from the spec's own examples: a quoted literal; a negative literal in a
binary expression; left-associative subtraction; `+` against `*`; a
four-element `sum` result; inclusive and reversed ranges; `Range.indices` order;
a repeated reference without a cycle; a direct and an indirect cycle; the three
`ParseError` inputs; numeric and date dispatch. Record actual results against the
supplied files. Keep simulated evidence labelled rehearsal.

Installed viewport checks: 740×420 default, 600×360 minimum, 1000×700 maximum,
small active display, long paths, wrapped code, long answers, selectable text,
reserved controls, exact return position, Hold/unread and Reduce Transparency.
Inspect bright and dark VS Code themes. Do not infer visual acceptance from tests.

Measure speech end to visible answer with two background model jobs and one
verification command active. Targets: warm short answers median ≤2 seconds and
p95 ≤4 seconds; already prepared step ≤300 ms after accepted advance. Report
sample count and cold/warm separation. No unmeasured latency claims.
