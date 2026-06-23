#!/usr/bin/env bash
# Regression tests for tools/test-matrix.sh — the cross-backend test runner.
#
# Proves:
#   (a) every backend green -> exit 0.
#   (b) one backend red -> exit 1, the red backend named (fail closed, §12.3).
#   (c) the §12.3 scenario: the SAME command green under one backend's env and red
#       under another's -> exit 1 (a single-backend run would have hidden it).
#   (d) per-backend env isolation: a var set for backend A is absent for backend B.
#   (e) usage errors: no --backend -> 2; no command after '--' -> 2.
set -euo pipefail
cd "$(dirname "$0")"
MX="../../test-matrix.sh"

PASS=0
FAIL=0
check() { # name expected actual [pattern] [out]
  local name="$1" ec="$2" ac="$3" pat="${4:-}" out="${5:-}" ok=1
  [[ "$ac" == "$ec" ]] || { ok=0; echo "  FAIL: $name — exit expected $ec got $ac"; }
  if [[ -n "$pat" ]] && ! grep -q "$pat" <<<"$out"; then ok=0; echo "  FAIL: $name — output missing /$pat/"; fi
  if [[ "$ok" == 1 ]]; then echo "  PASS: $name"; PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
run() { set +e; OUT=$(bash "$MX" "$@" 2>&1); CODE=$?; set -e; }

echo "test-matrix regression tests"

# (a) all green: 'true' passes under both backends.
run --backend sqlite --backend pg -- true
check "all-backends-green" 0 "$CODE" "all 2 backend(s) green" "$OUT"

# (b) one red: 'false' fails everywhere; the first backend is reported red.
run --backend sqlite --backend pg -- false
check "any-backend-red-exit" 1 "$CODE"
check "any-backend-red-names" 1 "$CODE" "red backend(s): sqlite pg" "$OUT"

# (c) §12.3: command passes only when BACKEND=ok; green under sqlite-as-ok, red under pg.
#     Without the matrix (sqlite only) this would have shipped green.
run --backend 'sqlite:BACKEND=ok' --backend 'pg:BACKEND=bad' -- sh -c '[ "$BACKEND" = ok ]'
check "cross-backend-defect-caught" 1 "$CODE" "red backend(s): pg" "$OUT"

# (d) env isolation: VAR exported for 'a' must NOT be visible when running 'b'.
#     Command fails iff VAR is set; so backend a (VAR set) is red, backend b is green.
run --backend 'a:VAR=1' --backend b -- sh -c '[ -z "${VAR:-}" ]'
check "env-isolation-a-red" 1 "$CODE" "red backend(s): a" "$OUT"

# (e) usage errors.
run -- true
check "no-backend-usage" 2 "$CODE"
run --backend sqlite
check "no-command-usage" 2 "$CODE"
run --backend sqlite --
check "empty-command-usage" 2 "$CODE"

echo "test-matrix: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
