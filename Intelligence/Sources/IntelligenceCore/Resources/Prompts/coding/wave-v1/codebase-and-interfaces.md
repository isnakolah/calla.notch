# Boundaries, and what the spec leaves open

`spec.md` has the published part 2 library. `part1-baseline.md` has the engine
and `Index` the project already builds on. This file is about the seams between
them, and about the decisions nobody has made yet.

## Seams in the submitted code

Locate the submitted part 1 storage, value conversion, reference resolution,
rendering and command boundaries before naming a file or function. Part 1 code
is authoritative only after inspecting this session's selected folder — the
published shape says what the interfaces were, not what the candidate wrote on
top of them.

Preserve raw input separately from evaluated typed values. A display string is
not a number. References should resolve through one evaluation boundary, so a
cycle is detected in one place rather than three. Keep range expansion at an
explicit function-argument boundary: `parse` hands back `'A1:A2'` as an opaque
string, and expanding it anywhere else spreads the supplied API through the
evaluator.

## Probe, do not remember

The preparation probe runs every documented fact in `spec.md` against the
installed libraries and writes the matches and differences to
`library-probe.md`. Read that file before trusting a signature. Where it records
a difference, the installed library wins and the difference is a question worth
raising.

Prior preparation examples are practice defaults, not facts about this session's
interfaces.

## Not settled by this pack

These are criterion 2 — the edge cases the spec leaves vague on purpose. Name
the ambiguity and propose one concrete reading; establish it with Angel rather
than deciding silently, and do not deduplicate or coerce behind the scenes.

- Blanks, strings and nested references inside a `sum` range.
- Repeated and overlapping references across arguments.
- Division by zero, and unsupported type combinations at the evaluation boundary.
- Fractional days, timezone handling, and how a date result is displayed.
- `sqrt` arity and its behaviour on a negative argument.
- What an unrecognised bare literal evaluates to.
