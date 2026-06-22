# acceptance-gate tests

Regression tests for `tools/acceptance-gate.sh` / `tools/acceptance_gate.py` —
the deterministic half of the autonomous build loop's whole-task acceptance gate.

## What it proves

The gate must judge a build on **external** signals (exit codes of real
commands), never on a model re-grading itself (arXiv:2310.01798). So the gate is
pure aggregation: a gate passes iff its command exits 0, and the build is
accepted iff every mandatory gate passes — **fail closed** on anything else.

| Fixture | Asserts | Exit |
|---|---|---|
| `fixture-all-pass.yaml` | every mandatory gate exits 0 → accepted | 0 |
| `fixture-mandatory-fail.yaml` | one mandatory gate fails → rejected | 3 |
| `fixture-nonmandatory-fail.yaml` | a failed advisory (non-mandatory) gate does not block | 0 |
| `fixture-no-mandatory.yaml` | gates present but none mandatory → refuse to auto-accept | 3 |
| `fixture-empty.yaml` | empty `gates` list is invalid config | 2 |
| `fixture-cmd-not-found.yaml` | a mandatory gate whose command does not exist → fail closed | 3 |
| (inline) missing config file | unreadable config → usage error | 2 |

Exit 3 (rejected build) is deliberately distinct from exit 2 (bad config/usage)
so the controlling loop can tell a *red build* from a *broken gate setup*.

## Run

```bash
bash tools/tests/acceptance-gate/run-tests.sh
```

Pure stdlib + PyYAML; gate commands in the fixtures are shell builtins
(`true`/`false`/`sh -c`), so the suite needs no network and touches no repo state.
