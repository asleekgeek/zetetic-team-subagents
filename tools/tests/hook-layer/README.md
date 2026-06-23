# hook-layer — C2 regression suite

Asserts the expected POST-FIX behaviour of the stdin hooks and the craftsmanship
checker after the `fix/hook-layer-enforcement` work. Each block maps to an audit
finding:

| Finding | Assertion |
|---|---|
| R1 | With `timeout`/`gtimeout` absent, a fed stdin payload is still parsed (the pre-commit guard still fires) — absence must not zero the payload. |
| R3 | `pre-tool-secret-shield.py` fed non-dict valid JSON (`[]` / `42` / `null`) fails OPEN (exit 0), not crash. |
| R4 | `stop-acceptance-gate.py` fed a non-dict payload allows the stop (exit 0, no `block`). |
| R5 | `stop-context-guard.py` fed a non-dict payload allows the stop (exit 0, no `block`). |
| A7 | `pre-commit-zetetic.sh` git-verb guard ignores `git` inside `echo`/`--grep`/`commit-tree`/`grep`, but fires on real `git commit` / `git push`. |

Plus the intentional-block contracts and the checker detectors:

- secret-shield **false-positive** corpus stays allowed (exit 0); **true-positive**
  corpus blocks (exit 2).
- craftsmanship-checker: `FILE_TOO_LONG` / `FUNCTION_TOO_LONG` / `PARAM_COUNT`
  fire and block (exit 1); `GRABBAG_NAME` advises (exit 0); a clean file passes
  (exit 0); `SEV_FILE_TOO_LONG=off` disables the file-size block (exit 0).

The A7 probe distinguishes "guard fired" from "guard quiet" by pointing
`CLAUDE_PLUGIN_ROOT` at an empty git repo so the hook prints the
`zetetic-checker.sh not found` sentinel only when the guard lets it fall through;
both paths exit 0, isolating the guard decision from any gate findings.

## Run

```sh
tools/tests/hook-layer/run-tests.sh
```

Exits non-zero on the first failing group's aggregate. Self-contained: all
fixtures live in a tmpdir; no working-tree or git mutation. Run only AFTER the
hook-layer fixes land (some target files may still be in flight otherwise).

> Note: the craftsmanship-checker detector cases are intentionally sized just
> past the §10 1.2x flex band so they BLOCK rather than merely advise, and use a
> `.c` fixture for `FILE_TOO_LONG` to avoid the slow per-line brace-nesting
> detector. Expect the checker portion to take a few seconds per case.
