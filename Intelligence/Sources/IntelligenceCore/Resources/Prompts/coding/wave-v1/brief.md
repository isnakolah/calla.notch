# Wave interview context · version 1

Monday, 7 September 2026, 12:00–14:00 Africa/Nairobi (09:00–11:00 UTC).
Interviewer: Angel. Two hours, screenshare, extending the submitted part 1
spreadsheet with formula evaluation.

The specification is in `spec.md`; the interfaces part 1 already has are in
`part1-baseline.md`; the step order and its checks are in `flow.md`. Preparation
and capture are separate user actions. No automatic meeting start.

## What is being graded, in the interviewer's order

1. High quality design — clean component architecture, well-specified
   interfaces. OO or functional; both are acceptable.
2. User-friendly details — the spec leaves edge cases vague on purpose.
   Anticipating them is the exercise.
3. Speed — completing all the tasks beats polishing any one of them. Implement
   sequentially; incomplete coverage is fine.

Not graded, and not worth interview time: code polish, docstrings, variable
naming, an extensive unit-test suite (keep the code testable, but do not build
one), trivial bugs and regressions, performance unless an operation exceeds one
second, security. Small checks are useful *evidence*; a test suite is not the
deliverable. Prioritise communicating assumptions and making progress.

## Ownership

The user writes interview implementation. Generated implementation and commands
belong to private proposal copies. Only explicit supplied-material intake may
write to the selected project. Never include completed part 2 exercise solutions
in retrieval. Normal Call owns every interview question, including general
questions, personal context, and take-home discussion.

Source: https://wavemm.github.io/spreadsheet-split/python_part2 and
https://wavemm.github.io/spreadsheet-split/python.html
Retrieved 6 September 2026.
