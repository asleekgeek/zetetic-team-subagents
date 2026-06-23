#!/usr/bin/env bash
#
# mutation-sweep.sh — the WIDE, NON-BLOCKING half of the two-tier mutation policy
# (rules/coding-standards.md §12.5). It sweeps the project's critical zones, runs
# the scoped mutation check (tools/mutation_check.sh) per zone, and writes a report
# that drives PROGRESSIVE iteration toward sufficient coverage. It ALWAYS exits 0.
#
# Why non-blocking: a broad mutation sweep over a whole project surfaces a long tail
# of survivors at once; gating commits on it would freeze the team for months
# (product-safety lesson 2026-06-10: heavy/broad automation must be report-only by
# default — every block requires explicit opt-in). The BLOCKING half is the
# per-commit scoped run (tools/mutation_check.sh on changed files only, via the git
# pre-commit hook): fast, narrow, must be green. This file is the wide net that lets
# us ratchet critical-zone coverage up one zone at a time, with evidence.
#
# Source: §12 builds on DeMillo, Lipton & Sayward (1978); Jia & Harman (2011).
#
#   usage: mutation-sweep.sh [--zones <file>] [--report <file>]
#     --zones   critical-zones config (default: memory/critical-zones.conf).
#               Format, one zone per line ('#' comments, blank lines ignored):
#                 label | source-file [source-file...] | test-path
#               (whitespace around '|' is trimmed; test-path may be empty for
#                tools whose per-repo config owns the test command)
#     --report  where to write the Markdown report (default: stdout)
#
# Exit code: always 0 (a health report, never a gate). Read the report; the
# per-zone status column tells you where to spend the next iteration.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ZONES="$ROOT/memory/critical-zones.conf"
REPORT=""
CHECK="$ROOT/tools/mutation_check.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --zones) ZONES="${2:?}"; shift 2 ;;
    --report) REPORT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "mutation-sweep: unexpected arg '$1'" >&2; exit 0 ;;  # non-blocking even on misuse
  esac
done

# Classify one zone's scoped mutation_check exit code into a report status.
status_for() {
  case "$1" in
    0) echo "clean" ;;       # 0 surviving mutants
    1) echo "SURVIVORS" ;;   # triage target — the next iteration's work
    3) echo "not-wired" ;;   # tool absent in this env (§12.2 per-repo wiring pending)
    4) echo "no-config" ;;   # repo lacks the tool's config (§12.2)
    2) echo "bad-zone" ;;    # malformed zone line (usage error from the checker)
    *) echo "error($1)" ;;
  esac
}

emit() { if [ -n "$REPORT" ]; then printf '%s\n' "$1" >>"$REPORT"; else printf '%s\n' "$1"; fi; }

# Pure-bash whitespace trim — avoids xargs, whose quote processing breaks on a
# stray apostrophe in a config line.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

[ -f "$ZONES" ] || { echo "mutation-sweep: no zones file at $ZONES (nothing to sweep)" >&2; exit 0; }
[ -n "$REPORT" ] && : >"$REPORT"

emit "# Mutation sweep — critical zones (non-blocking)"
emit ""
emit "| zone | files | status | detail |"
emit "|---|---|---|---|"

total=0; clean=0; survivors=0
while IFS='|' read -r label files tests; do
  # Skip blank and comment lines BEFORE trimming (a '#' line may hold apostrophes).
  case "$(trim "$label")" in ""|\#*) continue ;; esac
  label="$(trim "$label")"; files="$(trim "$files")"; tests="$(trim "$tests")"
  total=$((total + 1))

  args=()
  [ -n "$tests" ] && args+=(--tests "$tests")
  # shellcheck disable=SC2206
  args+=($files)
  set +e
  out="$(cd "$ROOT" && bash "$CHECK" "${args[@]}" 2>&1)"; code=$?
  set -e
  st="$(status_for "$code")"
  [ "$st" = "clean" ] && clean=$((clean + 1))
  [ "$st" = "SURVIVORS" ] && survivors=$((survivors + 1))
  detail="$(echo "$out" | tail -1 | sed 's/|/\\|/g')"
  emit "| $label | $files | $st | $detail |"
done < "$ZONES"

emit ""
emit "Swept $total zone(s): $clean clean, $survivors with survivors. Non-blocking —"
emit "triage one zone's survivors per iteration to ratchet critical-zone coverage (§12.5)."
exit 0
