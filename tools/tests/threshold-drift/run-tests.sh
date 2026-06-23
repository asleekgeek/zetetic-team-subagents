#!/usr/bin/env bash
# Regression test C1 — threshold drift-guard.
#
# coding-standards.md §4 declares the five hard size limits. The SINGLE
# human-readable source of truth is the §4 table in
#   rules/agent-reference/craftsmanship-moves.md
# ("the single source; do not recall these numbers from memory"). The MACHINE
# enforcer is tools/craftsmanship-checker.sh, which hardcodes the same five
# numbers as its default thresholds.
#
# If the two ever diverge — someone edits the doc table but not the checker, or
# vice versa — agents and the commit gate enforce different limits than the
# documented standard. This test pins them together: it greps the five numbers
# out of the §4 table and asserts each EQUALS the checker's hardcoded default.
# Any divergence FAILS (exit 1).
#
# The five limits (coding-standards.md §4):
#   File 500 / Function 50 / Class 300 / Parameters 4 / Nesting 3
#
# Strategy: pure text extraction — no execution of the checker (fast, hermetic).
set -euo pipefail
cd "$(dirname "$0")"

REPO="$(git rev-parse --show-toplevel 2>/dev/null || (cd ../../.. && pwd))"
MOVES="$REPO/rules/agent-reference/craftsmanship-moves.md"
CHECKER="$REPO/tools/craftsmanship-checker.sh"

PASS=0
FAIL=0
pass() { printf "  ok   %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  FAIL %s\n" "$1"; FAIL=$((FAIL + 1)); }

echo "C1 threshold drift-guard"

# ---- Preconditions -----------------------------------------------------------
[[ -f "$MOVES" ]]   || { echo "  FAIL precondition: $MOVES missing"; exit 1; }
[[ -f "$CHECKER" ]] || { echo "  FAIL precondition: $CHECKER missing"; exit 1; }

# ---- Extract the §4 table numbers from the doc -------------------------------
# Slice the "## §4" section (up to the next "## " heading), then pull the first
# integer out of each table row by its leading label. Robust to prose wording
# and bold markup (** **) around the number.
sec4() { awk '/^##[[:space:]]*§4/{f=1; next} /^## /{f=0} f' "$MOVES"; }

doc_row_int() { # $1 = row-label regex anchored at the cell start
  sec4 | grep -iE "^\|[[:space:]]*$1" | grep -oE '[0-9]+' | head -1
}

DOC_FILE="$(doc_row_int 'File')"
DOC_FUNC="$(doc_row_int 'Function')"
DOC_CLASS="$(doc_row_int 'Class')"
DOC_PARAM="$(doc_row_int 'Parameter')"
DOC_NEST="$(doc_row_int 'Nesting')"

# ---- Extract the checker's hardcoded defaults --------------------------------
# Lines look like:  FILE_MAX="${FILE_MAX:-500}"    # §4.1
checker_default() { # $1 = variable name
  grep -E "^$1=\"\\\$\{$1:-[0-9]+\}\"" "$CHECKER" \
    | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' | head -1
}

CK_FILE="$(checker_default FILE_MAX)"
CK_FUNC="$(checker_default FUNC_MAX)"
CK_CLASS="$(checker_default CLASS_MAX)"
CK_PARAM="$(checker_default PARAM_MAX)"
CK_NEST="$(checker_default NEST_MAX)"

# ---- Assert the documented values are the canonical five ---------------------
# Pin the DOC side to the literal §4 constants too, so a silent edit of BOTH the
# doc and the checker to a wrong-but-matching pair still fails.
assert_eq() { # name expected actual
  if [[ -z "$3" ]]; then fail "$1: could not extract a value (got empty)"; return; fi
  if [[ "$2" == "$3" ]]; then pass "$1 = $3"; else fail "$1: expected $2, got $3"; fi
}

echo " doc §4 table is the canonical five (coding-standards.md §4):"
assert_eq "doc File"      500 "$DOC_FILE"
assert_eq "doc Function"  50  "$DOC_FUNC"
assert_eq "doc Class"     300 "$DOC_CLASS"
assert_eq "doc Parameter" 4   "$DOC_PARAM"
assert_eq "doc Nesting"   3   "$DOC_NEST"

echo " checker default == doc §4 (no drift):"
assert_eq "FILE_MAX  vs doc File"      "$DOC_FILE"  "$CK_FILE"
assert_eq "FUNC_MAX  vs doc Function"  "$DOC_FUNC"  "$CK_FUNC"
assert_eq "CLASS_MAX vs doc Class"     "$DOC_CLASS" "$CK_CLASS"
assert_eq "PARAM_MAX vs doc Parameter" "$DOC_PARAM" "$CK_PARAM"
assert_eq "NEST_MAX  vs doc Nesting"   "$DOC_NEST"  "$CK_NEST"

echo
echo "C1 result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "C1 PASSED"
