# threshold-drift — C1 regression test

Pins the five size limits in `coding-standards.md` §4 across their two
representations so they cannot silently diverge:

- the human-readable §4 table in `rules/agent-reference/craftsmanship-moves.md`
  ("the single source; do not recall these numbers from memory"), and
- the hardcoded default thresholds in `tools/craftsmanship-checker.sh`
  (`FILE_MAX` / `FUNC_MAX` / `CLASS_MAX` / `PARAM_MAX` / `NEST_MAX`).

The canonical five: **File 500 / Function 50 / Class 300 / Parameters 4 /
Nesting 3**.

## Run

```sh
tools/tests/threshold-drift/run-tests.sh
```

Exits non-zero if the doc table and the checker defaults disagree, or if either
side has drifted off the canonical §4 constants. Pure text extraction — does not
execute the checker.
