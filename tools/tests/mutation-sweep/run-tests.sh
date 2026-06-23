#!/usr/bin/env bash
# Regression tests for tools/mutation-sweep.sh — the non-blocking critical-zones sweep.
#
# Proves:
#   (a) always exits 0 even when zones have survivors / unwired tools (non-blocking).
#   (b) the report has one table row per non-comment zone (scope iteration).
#   (c) status classification: a clean zone -> "clean", a tool-absent zone -> "not-wired".
#   (d) a missing zones file is reported and still exits 0 (never blocks).
#   (e) '#' comment and blank lines in the zones file are skipped.
set -euo pipefail
cd "$(dirname "$0")"
SWEEP="../../mutation-sweep.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { local name="$1" cond="$2"; if [ "$cond" = 1 ]; then echo "  PASS: $name"; PASS=$((PASS+1));
          else echo "  FAIL: $name"; FAIL=$((FAIL+1)); fi; }

echo "mutation-sweep regression tests"

# A stub checker lets us assert classification deterministically without real tools:
# exit 0 for a file named *clean*, exit 3 (tool-absent) otherwise.
STUB="$TMP/mutation_check.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *clean*) echo ">>> 0 surviving mutants"; exit 0 ;; esac; done
echo ">>> tool absent"; exit 3
EOF
chmod +x "$STUB"

ZONES="$TMP/zones.conf"
cat >"$ZONES" <<'EOF'
# a comment line — must be skipped

green-zone | src/clean_mod.py | tests/t.py
unwired-zone | src/other.py | tests/t.py
EOF

# Run the sweep with CHECK overridden to the stub (edit-free injection via a copy).
SWEEP_COPY="$TMP/mutation-sweep.sh"
sed "s#CHECK=\"\$ROOT/tools/mutation_check.sh\"#CHECK=\"$STUB\"#" "$SWEEP" > "$SWEEP_COPY"
REPORT="$TMP/report.md"
set +e; bash "$SWEEP_COPY" --zones "$ZONES" --report "$REPORT"; CODE=$?; set -e

check "exit-0-non-blocking" "$([ "$CODE" = 0 ] && echo 1 || echo 0)"
check "two-zone-rows" "$([ "$(grep -c '^| green-zone\|^| unwired-zone' "$REPORT")" = 2 ] && echo 1 || echo 0)"
check "clean-classified" "$(grep -q '^| green-zone .* clean ' "$REPORT" && echo 1 || echo 0)"
check "not-wired-classified" "$(grep -q '^| unwired-zone .* not-wired ' "$REPORT" && echo 1 || echo 0)"
check "comment-skipped" "$([ "$(grep -c '| a comment' "$REPORT")" = 0 ] && echo 1 || echo 0)"

# (d) missing zones file -> exit 0.
set +e; bash "$SWEEP_COPY" --zones "$TMP/nope.conf"; MISS=$?; set -e
check "missing-zones-exit-0" "$([ "$MISS" = 0 ] && echo 1 || echo 0)"

echo "mutation-sweep: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
