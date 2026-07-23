#!/usr/bin/env bash
# acceptance-gate.sh — deterministic whole-task acceptance gate for the
# autonomous build loop. Runs a configured set of command gates (zetetic-checker,
# test suites, contract-derived shell checks), aggregates their EXIT CODES, and
# returns an accept/reject verdict. No model judgement — a gate passes iff its
# command exits 0. This is what keeps the loop's convergence decision EXTERNAL
# (arXiv:2310.01798); the agent reviewers + residual compare-to-contract live in
# the controlling workflow and build on this verdict.
#
# Usage:
#   tools/acceptance-gate.sh [--config FILE]... [--root DIR] [--timeout SECONDS] \
#     [--diff-base REF --diff-head REF]
#
# --config : gate-config YAML (default: <root>/memory/acceptance-gates.yaml).
#            Repeatable — the loop passes a base config plus a contract-derived one.
# --root   : the repository the gates and the diff run in (default: git toplevel of
#            the current directory). Pass --root <repo> to gate ANY repository.
#
# Location-independent: the Python core is resolved as THIS script's sibling, not
# via the caller's working directory, so the gate can be invoked by absolute path
# from anywhere to gate a repo that does not contain this tooling.
#
# STDOUT  : verdict JSON {accepted, summary, gates[], unmet[], changed_files}.
# Exit codes: 0 accepted, 3 rejected (>=1 mandatory gate failed, none configured,
#             or empty diff), 2 usage/config error.
# Fails closed: an empty or unreadable gate set is a rejection, not an accept.
set -euo pipefail

# Resolve the Python core next to this script (BASH_SOURCE), so invoking the gate
# by absolute path from outside its home repo still finds it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_GATE="$SCRIPT_DIR/acceptance_gate.py"

# Resolve an interpreter that can import the core's one third-party dependency
# (PyYAML). Preference order:
#   1. python3 with yaml already importable (CI runners, machines with PyYAML
#      installed) — zero extra overhead, identical to the historical behavior.
#   2. `uv run` with a PINNED PyYAML — bootstraps a cached ephemeral environment
#      deterministically, so a bare python3 (e.g. Homebrew on macOS, which ships
#      no site packages) still runs the gate instead of crashing on import.
# Otherwise fail closed with exit 2 (usage/config error class): a gate that
# cannot run must be a loud error, never a silent skip or an auto-accept.
# pyyaml==6.0.3 — pinned for a deterministic bootstrap; current release with
# cp39–cp314 wheels. source: https://pypi.org/project/PyYAML/6.0.3/
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PYTHON_CMD=(python3)
elif command -v uv >/dev/null 2>&1; then
  PYTHON_CMD=(uv run --no-project --with 'pyyaml==6.0.3' python3)
else
  echo "acceptance-gate: python3 cannot import 'yaml' and 'uv' is not installed." >&2
  echo "acceptance-gate: install PyYAML (python3 -m pip install pyyaml) or uv (https://docs.astral.sh/uv/)." >&2
  exit 2
fi

# Default root = git toplevel of the CURRENT dir (back-compat for in-repo runs);
# the Python core takes the LAST --root it sees, so a caller's --root overrides this.
DEFAULT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT_CONFIG="${ACCEPTANCE_GATES_FILE:-$DEFAULT_ROOT/memory/acceptance-gates.yaml}"

# Inject the default --config only when the caller supplied none; always inject the
# default --root first so an explicit --root in "$@" wins by appearing after it.
case " $* " in
  *" --config "*) exec "${PYTHON_CMD[@]}" "$PYTHON_GATE" --root "$DEFAULT_ROOT" "$@" ;;
  *)              exec "${PYTHON_CMD[@]}" "$PYTHON_GATE" --root "$DEFAULT_ROOT" --config "$DEFAULT_CONFIG" "$@" ;;
esac
