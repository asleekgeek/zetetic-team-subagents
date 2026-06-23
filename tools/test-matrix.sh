#!/usr/bin/env bash
#
# test-matrix.sh — run ONE test command across a backend matrix, failing closed
# if any backend is red (rules/coding-standards.md §12.3 cross-backend discipline).
#
# A green suite on one backend can hide a real defect on another: the same module
# serving PostgreSQL and SQLite can pass under SQLite (returns float/str) yet break
# under PostgreSQL (returns numpy.float32/datetime the host can't serialize) —
# coverage was 100%, the bug shipped (§12.3, incident 2026-06-23). The fix is to
# run the SAME suite under EACH backend and require all green. This is the helper a
# `tests` acceptance gate calls so the loop's verdict spans backends, not just one.
#
# Source: §12.3 builds on DeMillo, Lipton & Sayward (1978); Jia & Harman (2011).
#
#   usage: test-matrix.sh --backend NAME[:ENV=VAL[;ENV=VAL...]] [--backend ...] \
#                         -- <test-command> [args...]
#     --backend  a backend to run under. NAME labels it; the optional ENV=VAL list
#                (';'-separated) is exported ONLY for that backend's run. A bare
#                NAME (no env) runs the command with the ambient environment — use
#                it for the default backend (e.g. SQLite).
#   e.g. test-matrix.sh \
#          --backend sqlite \
#          --backend 'pg:DATABASE_URL=postgresql://localhost:5432/cortex_test;CORTEX_BACKEND=pg' \
#          -- pytest tests_py/
#
# Exit codes (deterministic — this is a gate component):
#   0  every backend ran the command green
#   1  one or more backends were red (the report names which)
#   2  usage error (no backends, no '--' command)
set -euo pipefail

NAMES=()
ENVS=()
parse_backend() {
  # "name:A=1;B=2" -> NAMES+=(name), ENVS+=("A=1;B=2"); "name" -> ENVS+=("")
  local spec="$1" name env
  case "$spec" in
    *:*) name="${spec%%:*}"; env="${spec#*:}" ;;
    *)   name="$spec";       env="" ;;
  esac
  [ -n "$name" ] || { echo "test-matrix: empty backend name in '--backend $spec'" >&2; exit 2; }
  NAMES+=("$name"); ENVS+=("$env")
}

CMD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) [ $# -ge 2 ] || { echo "test-matrix: --backend needs a value" >&2; exit 2; }
               parse_backend "$2"; shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-matrix: unexpected arg '$1' (backends before '--', command after)" >&2; exit 2 ;;
  esac
done

[ "${#NAMES[@]}" -gt 0 ] || { echo "test-matrix: no --backend given" >&2; exit 2; }
[ "${#CMD[@]}" -gt 0 ] || { echo "test-matrix: no command after '--'" >&2; exit 2; }

# Run the command once per backend in an isolated subshell so one backend's env
# assignments never leak into the next. Collect each verdict; fail closed on any red.
RED=()
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  name="${NAMES[$i]}"; env="${ENVS[$i]}"
  echo ">>> backend '$name' — running: ${CMD[*]}"
  if (
        set -euo pipefail
        if [ -n "$env" ]; then
          # Export each ';'-separated ENV=VAL for this backend's run only.
          IFS=';' read -ra assigns <<< "$env"
          for a in "${assigns[@]}"; do export "${a?}"; done
        fi
        exec "${CMD[@]}"
     ); then
    echo ">>> backend '$name': GREEN"
  else
    echo ">>> backend '$name': RED (exit $?)" >&2
    RED+=("$name")
  fi
  i=$((i + 1))
done

if [ "${#RED[@]}" -gt 0 ]; then
  echo ">>> FAIL — red backend(s): ${RED[*]} (the same suite must be green on each, §12.3)" >&2
  exit 1
fi
echo ">>> all ${#NAMES[@]} backend(s) green: ${NAMES[*]}"
