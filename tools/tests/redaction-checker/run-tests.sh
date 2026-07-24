#!/usr/bin/env bash
# Regression suite — redaction-checker.sh (issue #43).
#
# Asserts:
#   T1 clean copy file → no findings, exit 0
#   T2 em dash in docs copy → EM_DASH finding, exit 0 (warn-only default)
#   T3 banned word → BANNED_WORD finding
#   T4 weasel phrase → WEASEL finding
#   T5 pattern inside a fenced code block → NOT flagged
#   T6 excluded path (skills/) → NOT scanned even when passed via --files
#   T7 strict profile (.zetetic.conf ZETETIC_PROFILE=strict) → findings exit 1
#   T8 usage error (no mode) → exit 2
set -uo pipefail

CHECKER="$(cd "$(dirname "$0")/../.." && pwd)/redaction-checker.sh"
PASS=0; FAIL=0

run_case() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name"; FAIL=$((FAIL+1)); fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q .
mkdir -p docs skills/writing

# T1 clean
printf 'This page explains the build. It cites Martin (2017), chapter 5.\n' > docs/clean.md
out=$("$CHECKER" --files docs/clean.md); rc=$?
run_case "T1 clean file: no findings, exit 0" test "$rc" -eq 0 -a -z "$out"

# T2 em dash (warn-only: exit 0 but finding printed)
printf 'The build is fast \xe2\x80\x94 very fast.\n' > docs/dash.md
out=$("$CHECKER" --files docs/dash.md); rc=$?
run_case "T2 em dash flagged" grep -q "EM_DASH" <<<"$out"
run_case "T2 em dash warn-only exit 0" test "$rc" -eq 0

# T3 banned word
printf 'We leverage a robust pipeline.\n' > docs/banned.md
out=$("$CHECKER" --files docs/banned.md)
run_case "T3 banned word flagged" grep -q "BANNED_WORD" <<<"$out"

# T4 weasel
printf 'Studies show this approach wins.\n' > docs/weasel.md
out=$("$CHECKER" --files docs/weasel.md)
run_case "T4 weasel flagged" grep -q "WEASEL" <<<"$out"

# T5 fenced code block not flagged
printf '%s\n' 'Real copy line.' '```' 'echo "studies show — leverage"' '```' > docs/fenced.md
out=$("$CHECKER" --files docs/fenced.md)
run_case "T5 fenced block ignored" test -z "$out"

# T6 excluded path not scanned
printf 'delve — studies show\n' > skills/writing/inventory-example.md
out=$("$CHECKER" --files skills/writing/inventory-example.md)
run_case "T6 skills/ path excluded" test -z "$out"

# T7 strict profile blocks
printf 'ZETETIC_PROFILE=strict\n' > .zetetic.conf
"$CHECKER" --files docs/weasel.md >/dev/null 2>&1; rc=$?
run_case "T7 strict profile exits 1" test "$rc" -eq 1
rm -f .zetetic.conf

# T8 usage error
"$CHECKER" >/dev/null 2>&1; rc=$?
run_case "T8 no mode exits 2" test "$rc" -eq 2

echo "----------------------------------------"
echo "redaction-checker suite: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
