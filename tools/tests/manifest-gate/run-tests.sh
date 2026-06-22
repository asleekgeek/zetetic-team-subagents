#!/usr/bin/env bash
# Regression tests for tools/manifest-gate.sh — the A->B membership gate.
#
# Proves:
#   (a) all-grounded passes, exercising RFC 3986 normalization (uppercase
#       scheme/host, explicit default :443, trailing slash, #fragment, and the
#       ' -> "passage"' provenance suffix) -> exit 0 + entry emitted on stdout.
#   (b) any ungrounded fact fails closed -> exit 3, gaps emitted, entry NOT
#       emitted (the whole entry is withheld from record).
#   (c) --drop keeps grounded facts and demotes ungrounded ones to gaps -> exit 0,
#       survivor has exactly the grounded fact + a gap naming the ungrounded source.
#   (d) an empty manifest grounds nothing -> exit 3 (fail closed).
#   (e) malformed stdin (manifest key missing) -> exit 2 (refuse, do not assume).
set -euo pipefail
cd "$(dirname "$0")"
GATE="../../manifest-gate.sh"

PASS=0
FAIL=0

check() { # name expected_code actual_code [grep_pattern] [stdout]
  local name="$1" ec="$2" ac="$3" grep_pat="${4:-}" out="${5:-}" ok=1
  if [[ "$ac" != "$ec" ]]; then ok=0; echo "  FAIL: $name — exit expected $ec got $ac"; fi
  if [[ -n "$grep_pat" ]] && ! grep -q "$grep_pat" <<<"$out"; then
    ok=0; echo "  FAIL: $name — stdout missing /$grep_pat/"
  fi
  if [[ "$ok" == 1 ]]; then echo "  PASS: $name"; PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

run() { # fixture [flags...] ; sets OUT, CODE
  local fixture="$1"; shift
  set +e
  OUT=$(bash "$GATE" "$@" < "$fixture" 2>/dev/null)
  CODE=$?
  set -e
}

echo "manifest-gate regression tests"

run fixture-all-grounded.json
check "all-grounded passes (normalization)" 0 "$CODE" '"query_id": "focused-crawler"' "$OUT"

run fixture-one-ungrounded.json
check "one ungrounded fails closed" 3 "$CODE" '"gaps"' "$OUT"
if grep -q '"summary"' <<<"$OUT"; then
  echo "  FAIL: ungrounded run leaked the entry onto stdout"; FAIL=$((FAIL + 1))
else
  echo "  PASS: ungrounded run withheld the entry"; PASS=$((PASS + 1))
fi

run fixture-one-ungrounded.json --drop
check "--drop emits survivor (exit 0)" 0 "$CODE" '"query_id": "focused-crawler"' "$OUT"
SHAPE=$(python3 -c '
import json, sys
d = json.load(sys.stdin)
facts = d.get("facts", [])
gaps = d.get("gaps", [])
one_fact = len(facts) == 1 and "Web_crawler" not in (facts[0].get("source") or "")
gap_named = any("Web_crawler" in (g.get("description") or "") for g in gaps)
print("yes" if one_fact and gap_named else "no")
' <<<"$OUT")
if [[ "$SHAPE" == yes ]]; then
  echo "  PASS: --drop kept exactly the grounded fact, ungrounded -> gap"; PASS=$((PASS + 1))
else
  echo "  FAIL: --drop survivor shape wrong (facts/gaps)"; FAIL=$((FAIL + 1))
fi

run fixture-empty-manifest.json
check "empty manifest grounds nothing" 3 "$CODE" '"gaps"' "$OUT"

run fixture-malformed.json
check "malformed stdin -> usage error" 2 "$CODE"

echo
echo "manifest-gate: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
