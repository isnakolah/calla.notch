# Part 1 baseline · what the project already has

Source: https://wavemm.github.io/spreadsheet-split/python.html — the take-home
this session extends. These are the interfaces the submitted code was written
against, so a move can name a real symbol instead of hunting for one. They are
still only the published shape: what the candidate actually built on top of them
comes from reading this session's selected folder.

## The engine

`sheet.engine.Spreadsheet` — the class part 1 implements. `sheet/engine.py`.

    get_formatted(index: Index) -> str   evaluated, then formatted per set_format
    get_raw(index: Index) -> str         the raw string last passed to set
    set(index: Index, raw: str)          '1', '2018-01-01', '=A2'
    set_format(index: Index, type: str, spec: str)
        type 'default' -> spec is None
        type 'number'  -> Python % format, '%.2f'
        type 'date'    -> strftime format, '%Y-%m-%d'

Part 1 implemented three tasks and was told to stop there: set/get_raw,
formatting, and following a reference in `get_formatted`. Formula evaluation
beyond a bare reference is this session's work.

Cell values are one of: a number (`1`, `1.23`, `6.02e23`), a datetime
(`2018-01-01` or `2018-01-01T13:45:56`), a string, a reference (`=A1`), or empty.
Raw input and evaluated typed value are different things; a display string is
neither.

## sheet.models.Index

Immutable, both coordinates zero-indexed.

    Index(row, col)
    Index.parse(label)   classmethod, case-insensitive, ValueError if invalid
                         'A1' -> Index(row=0, col=0); 'bb10' -> Index(row=9, col=27)
    row, col             zero-indexed ints
    row_label            1-indexed display; Index(1, 1).row_label == '2'
    column_label         A, B, ... Z, AA, BB, ... ; col 1 -> 'B', 27 -> 'BB', 53 -> 'BBB'
    str(index)           'BB10'
    index + other        Index or (row, col) tuple; sums both coordinates
    index.max(other)     greater of each coordinate
    index.min(other)     smaller of each coordinate

## Running it

Python 3.12. `python -m sheet`, or `python -m sheet ../examples/1-basic.csv`.
The `examples/` directory holds a CSV per task for the happy path.

**Logging goes to `spreadsheet.log`.** The curses UI paints over stdout, so a
`print()` is invisible — proposing one as a debugging step wastes a minute of a
two-hour interview and produces no output. See `sheet/__main__.py` for the
pattern the project already uses.

No required dependencies. Anything optional belongs in `requirements-dev.txt`.

## Branches

`part1` and `startingpoint` exist from the take-home submission. The supplied
material arrives on `part2`.
