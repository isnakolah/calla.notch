# Published part 2 spec · fact, not expectation

Source: https://wavemm.github.io/spreadsheet-split/python_part2
Retrieved 6 September 2026. This file is the specification. Where it is exact,
it is exact; do not hedge it back into "the library might". Where it is vague,
it is vague deliberately — see "What is left open" at the end.

Two hours, screenshare, extending the submitted part 1 spreadsheet. Two new
libraries arrive at the start.

## Arrival

The supplied part-2 files are put into the project folder directly. There is no
import or merge step, so the tree Prepare probes is the tree the session runs
against. `sheet/formula.py` appearing in the package is what "the library has
arrived" means.

## What formulas must support

A formula is a cell value starting with `=`. Inside it:

- Cell references, `A1`. Already implemented in part 1; may be refactored onto
  the new parser.
- Literal numbers or dates, `6.02e23`, `2018-01-01`.
- Binary operators `+ - * /` on sub-expressions. Spaces required on both sides.
  All four are defined for numbers. For dates only addition and subtraction are:
  a date plus a number is a later date, a date minus a date is a day difference,
  and two dates cannot be added.
- Function calls, `sum(A1:B2, C3:D4)`. Names are alphanumeric and
  case-insensitive. Any number of arguments.
- Ranges, `A1:B3` — two cell references separated by a colon, operating on many
  cells. The supplied library converts references and ranges to and from tuples.

A cell holding a formula displays the **result of evaluating it**. A set of
formulas that forms a circular reference — `A1` is `=A2` and `A2` is `=A1` —
must not hang and must not crash.

## sheet.formula

`ParseError` — raised for a syntactically invalid formula.

`parse(formula)` — parses a formula **without** its leading `=`. Returns a
**string** for a reference or a literal, and a **list** for a binary operator or
a function call, whose first element is the operator or function name and whose
remaining elements are the operands. Recurse on the operands.

The published examples, exactly:

    parse('A1')                  -> 'A1'
    parse('2018-01-01')          -> '2018-01-01'
    parse('6.02e23')             -> '6.02e23'
    parse('miscellaneousliteral')-> 'miscellaneousliteral'
    parse('"string with spaces"')-> 'string with spaces'
    parse('A1 + A2')             -> ['+', 'A1', 'A2']
    parse('-1 + 2')              -> ['+', '-1', '2']
    parse('2 + -1')              -> ['+', '2', '-1']
    parse('A1 - A2 - A3')        -> ['-', ['-', 'A1', 'A2'], 'A3']
    parse('A1 - (A2 - A3)')      -> ['-', 'A1', ['-', 'A2', 'A3']]
    parse('A1 + A2 * A3')        -> ['+', 'A1', ['*', 'A2', 'A3']]
    parse('sum(A1:A2)')          -> ['sum', 'A1:A2']
    parse('sum(A1:A2, A3, A4)')  -> ['sum', 'A1:A2', 'A3', 'A4']
    parse('sqrt((1+1))')         -> ['sqrt', ['+', '1', '1']]
    parse('A1 + sqrt(A2 + A3)')  -> ['+', 'A1', ['sqrt', ['+', 'A2', 'A3']]]
    parse('a1:b1(1, 2, 3)')      -> ParseError
    parse('1 + ')                -> ParseError
    parse('')                    -> ParseError

Five of these are load-bearing and easy to get wrong:

- A quoted literal comes back **unquoted**: `'"string with spaces"'` is
  `'string with spaces'`. Quoting is a parser concern, not an evaluator one.
- A negative number stays inside its leaf: `'-1 + 2'` is `['+', '-1', '2']`,
  not a unary minus node. Leaf-to-value conversion has to accept the sign.
- Subtraction is left-associative: `'A1 - A2 - A3'` nests on the **left**.
- `*` binds tighter than `+`, so the tree is already in precedence order —
  evaluate it as given rather than re-deriving precedence.
- **A list is not always three elements.** `['sum', 'A1:A2', 'A3', 'A4']` has
  four. Anything that unpacks a result as `op, left, right` breaks on the first
  multi-argument call.

A range argument arrives as a plain string, `'A1:A2'` — the parser does not
expand it.

## sheet.models.Range

`Range(pos1, pos2)` from two `Index` values. `first` and `last` are **inclusive**:
`A1:B2` includes column B and row 2. Endpoints given in the wrong order are
rearranged by the constructor — `Range(Index(1, 0), Index(0, 1)).first` is
`Index(row=0, col=0)`.

    Range.parse(desc)   classmethod; 'A1:B3'; raises ValueError if not a range
    str(range)          human syntax, 'A1:B2'
    first               top-left Index
    last                bottom-right included Index
    contains(pos)       'B2:C3' contains 'C3'; not 'C4'; not 'D3'
    height              'A1:B3' -> 3
    width               'A1:B3' -> 2
    indices             every Index in the range, row-major:
                        'A1:B3' -> A1, B1, A2, B2, A3, B3
    row(i)              the i-th row: 'A1:C3'.row(1) -> A2, B2, C2

## Recommended order

References, then literals, then binary operators on numbers, then `sum`. Then,
if time allows, binary operators on dates, then `sqrt`.

## How this is graded

In the interviewer's own ranking:

1. High quality design — clean component architecture, well-specified
   interfaces. OO or functional, either is acceptable.
2. User-friendly details — the spec leaves edge cases vague on purpose.
   Anticipating them is the exercise, not a bonus.
3. Speed — completing all the tasks matters more than polishing any one of
   them. Implement sequentially; incomplete coverage is fine.

Explicitly **not** graded, and not worth interview time: code polish, docstrings,
variable naming, a unit-test suite (keep the code testable, but do not build
one), trivial bugs and regressions, performance unless an operation exceeds one
second, security.

## What is left open

The spec does not settle these, and criterion 2 is precisely about them. Name
the ambiguity out loud and propose one concrete reading; do not decide quietly.

- Blank cells, strings and references inside a `sum` range.
- Repeated or overlapping references across arguments — sum twice, or once?
- Division by zero, and operators on mismatched types.
- Fractional days, `date - number`, timezones, and how a date result displays.
- `sqrt` arity and its behaviour on a negative argument.
- What an unrecognised bare literal such as `miscellaneousliteral` means once
  evaluated.

One inconsistency in the published text is worth knowing before it bites: the
prose says spaces are required on both sides of an operator, but the example
`parse('sqrt((1+1))')` parses `1+1` with none. The preparation probe records
which the shipped parser actually does.
