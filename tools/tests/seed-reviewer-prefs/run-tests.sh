#!/usr/bin/env bash
# Regression tests for tools/seed-reviewer-prefs.sh — the CAP-2 reviewer-prefs seeder.
#
# Proves:
#   (a) gh not authenticated -> exit 3 (fail closed, clear message).
#   (b) no evidence for the lead -> exit 4 (nothing to seed).
#   (c) happy dry-run -> exit 0; draft carries status: inferred, the lead, the
#       evidence, and explicitly says nothing was written.
#   (d) happy --write -> exit 0; the draft is persisted to the reviewer-prefs scope
#       as an owner (orchestrator) and is readable back; ACL holds (real memory-tool).
#   (e) usage errors: no lead -> 2; bad login -> 2; non-owner --owner-id -> 2.
# The gh stub (bin/gh) returns canned formatted output; we test OUR orchestration.
set -euo pipefail
cd "$(dirname "$0")"
TOOL="../../seed-reviewer-prefs.sh"
export PATH="$PWD/bin:$PATH"        # gh stub shadows the real gh
chmod +x bin/gh

PASS=0; FAIL=0
check() { # name expected-exit actual-exit [pattern] [output]
  local name="$1" ec="$2" ac="$3" pat="${4:-}" out="${5:-}" ok=1
  [[ "$ac" == "$ec" ]] || { ok=0; echo "  FAIL: $name — exit expected $ec got $ac"; }
  if [[ -n "$pat" ]] && ! grep -q "$pat" <<<"$out"; then ok=0; echo "  FAIL: $name — output missing /$pat/"; fi
  if [[ "$ok" == 1 ]]; then echo "  PASS: $name"; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}
run() { set +e; OUT=$(bash "$TOOL" "$@" 2>&1); CODE=$?; set -e; }

echo "seed-reviewer-prefs regression tests"

# (a) not authenticated -> 3
GH_AUTH=fail run alice
check "gh-not-authenticated-exit" 3 "$CODE"
check "gh-not-authenticated-msg" 3 "$CODE" "not authenticated" "$OUT"

# (b) no evidence -> 4
GH_EMPTY=1 run alice
check "no-evidence-exit" 4 "$CODE"
check "no-evidence-msg" 4 "$CODE" "nothing to seed" "$OUT"

# (c) dry-run happy path -> 0, carries the evidence + inferred status + no-write note
run alice
check "dryrun-exit" 0 "$CODE"
check "dryrun-status-inferred" 0 "$CODE" "status: inferred" "$OUT"
check "dryrun-has-lead" 0 "$CODE" "Inferred review preferences — alice" "$OUT"
check "dryrun-has-comment-evidence" 0 "$CODE" "prefer Result over exceptions" "$OUT"
check "dryrun-has-pr-evidence" 0 "$CODE" "Fix the retry loop" "$OUT"
check "dryrun-says-no-write" 0 "$CODE" "dry-run (no write)" "$OUT"

# (d) --write happy path -> 0, persisted to the scope as orchestrator, readable back
LEAD="seedtest-$$"
cleanup() { rm -rf "$HOME/.claude/memories/reviewer-prefs/$LEAD" 2>/dev/null || true; }
trap cleanup EXIT
run "$LEAD" --write
check "write-exit" 0 "$CODE"
check "write-confirms-path" 0 "$CODE" "wrote /memories/reviewer-prefs/$LEAD/inferred.md" "$OUT"
set +e
BACK=$(MEMORY_AGENT_ID=code-reviewer bash ../../memory-tool.sh view "/memories/reviewer-prefs/$LEAD/inferred.md" 2>&1); RC=$?
set -e
check "write-readable-by-reader" 0 "$RC" "status: inferred" "$BACK"

# (d2) ACL holds at the storage layer: a reviewed agent (non-owner) cannot write a pref.
set +e
ACL=$(MEMORY_AGENT_ID=engineer bash ../../memory-tool.sh create "/memories/reviewer-prefs/$LEAD/sneak.md" "x" 2>&1); ARC=$?
set -e
check "acl-blocks-nonowner-write" 1 "$([ $ARC -ne 0 ] && echo 1 || echo 0)" "not permitted to write" "$ACL"

# (e) usage errors
run
check "usage-no-lead" 2 "$CODE"
run "bad login!"
check "usage-bad-login" 2 "$CODE"
run alice --owner-id engineer
check "usage-nonowner-write-id" 2 "$CODE"
run alice --limit 0
check "usage-limit-zero-rejected" 2 "$CODE"
run alice --repo "not-a-repo"
check "usage-bad-repo-rejected" 2 "$CODE"

echo "----"
echo "seed-reviewer-prefs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
