#!/usr/bin/env bash
# Regression tests for tools/acceptance-gate.sh — the deterministic acceptance gate.
#
# Proves:
#   (a) all mandatory gates exit 0          -> accepted, exit 0
#   (b) a failed mandatory gate             -> rejected, exit 3
#   (c) a failed NON-mandatory gate         -> does not block, exit 0
#   (d) gates present but none mandatory    -> fail closed, exit 3
#   (e) an empty gates list (invalid)       -> config error, exit 2
#   (f) a command-not-found mandatory gate  -> fail closed, exit 3
#   (g) a missing config file               -> usage error, exit 2
set -euo pipefail
cd "$(dirname "$0")"
GATE="../../acceptance-gate.sh"

PASS=0
FAIL=0

check() { # name expected_code actual_code [grep_pattern] [stdout]
  local name="$1" ec="$2" ac="$3" gp="${4:-}" out="${5:-}" ok=1
  if [[ "$ac" != "$ec" ]]; then ok=0; echo "  FAIL: $name — exit expected $ec got $ac"; fi
  if [[ -n "$gp" ]] && ! grep -q "$gp" <<<"$out"; then ok=0; echo "  FAIL: $name — stdout missing /$gp/"; fi
  if [[ "$ok" == 1 ]]; then echo "  PASS: $name"; PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

run() { # config-path [extra gate flags...] ; sets OUT, CODE
  set +e
  OUT=$(bash "$GATE" --config "$@" 2>/dev/null)
  CODE=$?
  set -e
}

echo "acceptance-gate regression tests"

run fixture-all-pass.yaml
check "all mandatory pass -> accepted" 0 "$CODE" '"accepted": true' "$OUT"

run fixture-mandatory-fail.yaml
check "failed mandatory -> rejected" 3 "$CODE" '"accepted": false' "$OUT"

run fixture-nonmandatory-fail.yaml
check "failed advisory does not block" 0 "$CODE" '"accepted": true' "$OUT"

run fixture-no-mandatory.yaml
check "no mandatory gates fails closed" 3 "$CODE" 'no mandatory gates' "$OUT"

run fixture-empty.yaml
check "empty gate list -> config error" 2 "$CODE"

run fixture-cmd-not-found.yaml
check "command-not-found mandatory -> rejected" 3 "$CODE" '"accepted": false' "$OUT"

run ./nonexistent-config-file.yaml
check "missing config -> usage error" 2 "$CODE"

# --- diff scoping (deterministic, tool-owned scope) ---
run fixture-files.yaml
check "{files} token without --diff-base -> usage error" 2 "$CODE"

run fixture-all-pass.yaml --diff-base HEAD --diff-head HEAD
check "empty diff (HEAD...HEAD) -> rejected, fail closed" 3 "$CODE" 'empty-diff' "$OUT"

if git -C "$(git rev-parse --show-toplevel)" rev-parse HEAD~1 >/dev/null 2>&1; then
  run fixture-files.yaml --diff-base HEAD~1 --diff-head HEAD
  check "{files} substituted over a real range -> accepted" 0 "$CODE" '"accepted": true' "$OUT"
else
  echo "  SKIP: {files} substitution over a real range (no HEAD~1)"
fi

# --- external repo, foreign cwd (the loop runs "from anywhere") ---
# Resolve the gate to an absolute path, build a throwaway repo elsewhere, and gate
# it with --root from a cwd that is NOT this repo (and not even a git work tree).
# Proves the runner self-locates its Python core and that gates + diff run in
# --root, never the caller's cwd.
GATE_ABS="$(cd "$(dirname "$GATE")" && pwd)/$(basename "$GATE")"
EXT_WORK="$(mktemp -d)"
EXT="$EXT_WORK/extrepo"
mkdir -p "$EXT"
git -C "$EXT" init -q
git -C "$EXT" config user.email t@t.t
git -C "$EXT" config user.name t
printf 'one\n' >"$EXT/a.txt"
git -C "$EXT" add -A && git -C "$EXT" commit -qm c1 >/dev/null
printf 'two\n' >"$EXT/b.txt"
git -C "$EXT" add -A && git -C "$EXT" commit -qm c2 >/dev/null
printf 'version: 1\ngates:\n  - {name: ext-cwd, cmd: "test -f b.txt", mandatory: true}\n  - {name: ext-files, cmd: "echo {files}", mandatory: true}\n' >"$EXT_WORK/gate.yaml"
set +e
OUT=$(cd "$EXT_WORK" && bash "$GATE_ABS" --config "$EXT_WORK/gate.yaml" --root "$EXT" --diff-base HEAD~1 --diff-head HEAD 2>/dev/null)
CODE=$?
set -e
check "external repo from foreign cwd -> accepted" 0 "$CODE" '"accepted": true' "$OUT"
check "external diff + gates scoped to --root (b.txt)" 0 "$CODE" 'b.txt' "$OUT"

# A home-repo-relative base gate (cmd references a script absent from the foreign tree) MUST fail closed
# when run with --root the external repo — never silently accept, never bind to a foreign same-named
# script. This is the safety property behind the loop's external=contract-only default for gateConfig.
printf 'version: 1\ngates:\n  - {name: home-only-tool, cmd: "bash tools/zetetic-checker.sh --files {files}", mandatory: true}\n' >"$EXT_WORK/home-base.yaml"
set +e
OUT=$(cd "$EXT_WORK" && bash "$GATE_ABS" --config "$EXT_WORK/home-base.yaml" --root "$EXT" --diff-base HEAD~1 --diff-head HEAD 2>/dev/null)
CODE=$?
set -e
check "home-relative base gate over external --root -> fail closed" 3 "$CODE" '"accepted": false' "$OUT"
rm -rf "$EXT_WORK"

echo
echo "acceptance-gate: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
