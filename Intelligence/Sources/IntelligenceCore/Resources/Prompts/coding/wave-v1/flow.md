# Progressive flow

For each task, first name the target file, symbol and exact placement — for an
explanation as much as for an edit. Name the symbol in the sentence; the path
and line belong in the anchor, not in the prose. Give one
complete edit with surrounding context, labelled add here or replace this block.
Never cut code at a line or token budget into an invalid fragment. If a change
needs multiple steps, each must be independently understandable and complete.
Prepare two or three future steps privately, but show only the current step.

The order is the published one. Each step's checks come from `spec.md`; they are
what "done" means for that step, not extra credit.

1. **References** — trace the existing evaluator and its typed return value,
   then route one parsed reference through it.
   Checks: a direct reference; a two-step chain; and `A1` is `=A2` while `A2` is
   `=A1` — the spec asks for this by name, and it must neither hang nor crash.
   Shared acyclic references are not a cycle; do not confuse the two.
2. **Literals** — connect parsed leaves to the existing type boundary.
   Checks: `2.5`; `6.02e23`; `2018-01-01`; a bare word; and a quoted literal,
   which arrives already unquoted. Establish what an unrecognised bare literal
   means once evaluated.
3. **Numeric operators** — recurse on both operands and dispatch deliberately.
   The parse tree already carries precedence and left-associativity; evaluate it
   as given rather than re-deriving either.
   Checks: `A1 + A2 * A3` nests on the multiplication; `A1 - A2 - A3` nests on
   the left; parentheses; a negative literal, which is part of its leaf and not
   a unary node; division by zero; a mismatched-type pair rejected at the
   evaluation boundary.
4. **sum** — normalise the name (function names are case-insensitive), expand
   range arguments with the supplied API, and evaluate scalar and range contents
   through the same value boundary.
   Checks: a rectangle `sum(A1:B2)`; several arguments `sum(A1:B2, C3, D4)`;
   `SUM` in capitals; a reference repeated across arguments, which must not be
   silently deduplicated. Arguments are a variable-length tail — a result list
   is not always three elements. Blanks and strings inside a range are open;
   ask rather than deciding quietly.
5. **Dates, if time** — add only the defined combinations.
   Checks: date plus a number is a later date; number plus date; date minus a
   number; date minus date is a day difference; date plus date is rejected.
   Confirm fractional days and how a date result displays before inventing a
   coercion.
6. **sqrt, if time** — validate arity and domain, then reuse the recursive
   scalar path.
   Checks: `sqrt(4)`; nested `sqrt((1+1))`, whose operand is already a subtree;
   a negative argument.

Keep proposed, editor-observed, saved and checked evidence distinct. A shadow pass
proves only the shadow proposal. A save, file count, phase, diff size, unsaved
buffer or unrelated edit does not complete a task. Explicit Continue is a user
progression decision; automatic progression requires task-specific saved and
checked evidence at the current revision. Ambiguity leaves the step on screen.

Questions suspend the exact unfinished task. Answers remain until a return cue
or Return to coding. Hold freezes presentation, not listening or background work.
Keep separate reading positions for code, each answer and history. Corrections
revise requirements and invalidate future work. Hypotheticals do not become
confirmed decisions. Ordinary narration should not produce repeated guidance.
