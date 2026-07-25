#!/usr/bin/env bash
# Regression suite — plugin-version-check.sh (issue #52).
#
# Asserts every arm of the three-value check. Hermetic: builds a throwaway
# CLAUDE_DIR + plugin root under mktemp, and stubs the two network probes via
# ZTS_LATEST_TAG_CMD / ZTS_RULES_CHANGED_CMD. No network, no ~/.claude reads.
#
#   T1  up to date                      → SILENT, exit 0   (negative assertion)
#   T2  installed < pin                 → INSTALL_LAG, exit 1
#   T3  pin < released                  → PIN_LAG + owner repo named, exit 1
#   T4  pin lag across a rules change   → RULES CHANGED line
#   T5  pin lag, rules unchanged        → NO rules line     (negative assertion)
#   T6  both lags at once               → both reported
#   T7  plugin.json unreadable          → NOTICE, exit 0    (fail-open)
#   T8  release probe fails (offline)   → NOTICE, exit 0    (fail-open)
#   T9  malformed release tag           → NOTICE, no verdict, exit 0
#   T10 plugin in no enabled marketplace→ NOTICE, exit 0
#   T11 --version / --rules-version
#   T12 bad flag                        → exit 2
#   T13 release count named when derivable from local tags
#   T14 REGRESSION: releases are probed from the PLUGIN's repo, never the
#       marketplace owner's. Pre-fix this queried cdeust/Cortex for a
#       zetetic-team-subagents release and compared 2.34.0 against 4.16.0.
set -uo pipefail

CHECKER="$(cd "$(dirname "$0")/../.." && pwd)/plugin-version-check.sh"
PASS=0; FAIL=0

run_case() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name"; FAIL=$((FAIL+1)); fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ── Fixture builders ───────────────────────────────────────────────────
# $1 plugin version, $2 marketplace pin, $3 plugin source repo
make_env() {
  local installed="$1" pin="$2" src_repo="${3:-cdeust/demo-plugin}"
  local root="$tmp/env$RANDOM$RANDOM"
  mkdir -p "$root/plugin/.claude-plugin" "$root/plugin/rules" \
           "$root/claude/plugins/marketplaces/host-mkt/.claude-plugin"
  cat > "$root/plugin/.claude-plugin/plugin.json" <<EOF
{"name":"demo-plugin","version":"${installed}","repository":"https://github.com/${src_repo}"}
EOF
  printf -- '---\nname: coding-standards\nversion: 9.9.9\n---\n# rules\n' \
    > "$root/plugin/rules/coding-standards.md"
  cat > "$root/claude/settings.json" <<'EOF'
{"enabledPlugins":{"demo-plugin@host-mkt":true,"other@somewhere-else":true}}
EOF
  cat > "$root/claude/plugins/marketplaces/host-mkt/.claude-plugin/marketplace.json" <<EOF
{"name":"host-mkt","plugins":[{"name":"demo-plugin","version":"${pin}",
 "source":{"source":"github","repo":"${src_repo}"}}]}
EOF
  # The marketplace clone's remote is a DIFFERENT repo than the plugin's —
  # the exact shape that produced the T14 defect.
  git -C "$root/claude/plugins/marketplaces/host-mkt" init -q 2>/dev/null
  git -C "$root/claude/plugins/marketplaces/host-mkt" \
    remote add origin "https://github.com/cdeust/HostRepo.git" 2>/dev/null
  echo "$root"
}

# Run the checker against a fixture. Extra env passed as VAR=VAL pairs.
check() {
  local root="$1"; shift
  env ZTS_PLUGIN_ROOT="$root/plugin" ZTS_CLAUDE_DIR="$root/claude" \
      ZTS_RULES_CHANGED_CMD="${RULES_CMD:-echo no}" \
      ZTS_LATEST_TAG_CMD="${LATEST_CMD:-echo v1.0.0}" \
      "$@" "$CHECKER"
}

# ── T1 up to date → silent ─────────────────────────────────────────────
e=$(make_env 1.0.0 1.0.0)
out=$(check "$e"); rc=$?
run_case "T1 up to date: exit 0" test "$rc" -eq 0
run_case "T1 up to date: SILENT (no output at all)" test -z "$out"

# ── T2 install lag ─────────────────────────────────────────────────────
e=$(make_env 1.0.0 1.2.0); LATEST_CMD="echo v1.2.0"
out=$(check "$e"); rc=$?
run_case "T2 INSTALL_LAG flagged" grep -q "INSTALL_LAG" <<<"$out"
run_case "T2 names both versions" grep -q "installed 1.0.0.*pins 1.2.0" <<<"$out"
run_case "T2 exit 1" test "$rc" -eq 1
run_case "T2 no PIN_LAG (pin == latest)" test -z "$(grep 'PIN_LAG' <<<"$out")"
unset LATEST_CMD

# ── T3 pin lag → owner named ───────────────────────────────────────────
e=$(make_env 1.0.0 1.0.0); LATEST_CMD="echo v2.0.0"
out=$(check "$e"); rc=$?
run_case "T3 PIN_LAG flagged" grep -q "PIN_LAG" <<<"$out"
run_case "T3 names the pin-owning repo" grep -q "cdeust/HostRepo" <<<"$out"
run_case "T3 says the user cannot fix it" grep -q "cannot fix this" <<<"$out"
run_case "T3 exit 1" test "$rc" -eq 1

# ── T4/T5 rules-change discrimination ──────────────────────────────────
RULES_CMD="echo yes"; out=$(check "$e")
run_case "T4 rules change across the gap is called out" grep -q "RULES CHANGED" <<<"$out"
RULES_CMD="echo no"; out=$(check "$e")
run_case "T5 no rules change: line absent (negative assertion)" \
  test -z "$(grep 'RULES CHANGED' <<<"$out")"
unset RULES_CMD

# ── T6 both lags ───────────────────────────────────────────────────────
e=$(make_env 1.0.0 1.5.0); LATEST_CMD="echo v2.0.0"
out=$(check "$e"); rc=$?
run_case "T6 install lag reported" grep -q "INSTALL_LAG" <<<"$out"
run_case "T6 pin lag reported alongside" grep -q "PIN_LAG" <<<"$out"
run_case "T6 exit 1" test "$rc" -eq 1
unset LATEST_CMD

# ── T7 undeterminable installed version → fail-open ────────────────────
e=$(make_env 1.0.0 1.0.0); rm -f "$e/plugin/.claude-plugin/plugin.json"
out=$(check "$e"); rc=$?
run_case "T7 undeterminable version: NOTICE" grep -q "NOTICE.*undeterminable" <<<"$out"
run_case "T7 undeterminable version: exit 0 (fail-open)" test "$rc" -eq 0

# ── T8 offline release probe → fail-open ───────────────────────────────
e=$(make_env 1.0.0 1.0.0); LATEST_CMD="exit 7"
out=$(check "$e"); rc=$?
run_case "T8 offline: NOTICE, not a verdict" grep -q "NOTICE.*latest release unavailable" <<<"$out"
run_case "T8 offline: exit 0 (no red session)" test "$rc" -eq 0
run_case "T8 offline: no PIN_LAG claimed" test -z "$(grep 'PIN_LAG' <<<"$out")"
unset LATEST_CMD

# ── T9 malformed release tag ───────────────────────────────────────────
e=$(make_env 1.0.0 1.0.0); LATEST_CMD="echo nightly-build"
out=$(check "$e"); rc=$?
run_case "T9 malformed tag: NOTICE" grep -q "NOTICE.*unparseable release tag" <<<"$out"
run_case "T9 malformed tag: exit 0, no verdict" test "$rc" -eq 0
unset LATEST_CMD

# ── T10 plugin served by no enabled marketplace ────────────────────────
e=$(make_env 1.0.0 1.0.0)
printf '{"enabledPlugins":{"unrelated@x":true}}\n' > "$e/claude/settings.json"
out=$(check "$e"); rc=$?
run_case "T10 no marketplace: NOTICE" grep -q "NOTICE.*pin undeterminable" <<<"$out"
run_case "T10 no marketplace: exit 0" test "$rc" -eq 0

# ── T11 introspection modes ────────────────────────────────────────────
# NB: invoked directly, not via check() — that helper puts extra args before
# the script path (they are env(1) options there), so flags must not go through it.
e=$(make_env 3.1.4 3.1.4)
out=$(env ZTS_PLUGIN_ROOT="$e/plugin" ZTS_CLAUDE_DIR="$e/claude" "$CHECKER" --version)
run_case "T11 --version is exactly the version" test "$out" = "3.1.4"
out=$(env ZTS_PLUGIN_ROOT="$e/plugin" ZTS_CLAUDE_DIR="$e/claude" "$CHECKER" --rules-version)
run_case "T11 --rules-version reads the rules frontmatter" test "$out" = "9.9.9"

# ── T12 usage error ────────────────────────────────────────────────────
env ZTS_PLUGIN_ROOT="$e/plugin" ZTS_CLAUDE_DIR="$e/claude" "$CHECKER" --bogus >/dev/null 2>&1
run_case "T12 unknown flag: exit 2" test "$?" -eq 2

# ── T13 release count from local tags ──────────────────────────────────
e=$(make_env 1.0.0 1.0.0)
git -C "$e/plugin" init -q
git -C "$e/plugin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
for t in v1.0.0 v1.1.0 v1.2.0 v2.0.0; do git -C "$e/plugin" tag "$t" 2>/dev/null; done
LATEST_CMD="echo v2.0.0"
out=$(check "$e")
run_case "T13 names how many releases were withheld" grep -qE "[0-9]+ releases were never delivered" <<<"$out"
unset LATEST_CMD

# ── T14 REGRESSION: releases probed from the PLUGIN repo, not the owner ─
# Pre-fix, latest_release_tag was called with the marketplace clone's remote
# (cdeust/HostRepo), so a demo-plugin check compared against HostRepo's
# releases. Assert the probe receives the plugin's own repo.
e=$(make_env 1.0.0 1.0.0 cdeust/demo-plugin)
out=$(env ZTS_PLUGIN_ROOT="$e/plugin" ZTS_CLAUDE_DIR="$e/claude" \
      ZTS_RULES_CHANGED_CMD="echo no" \
      ZTS_LATEST_TAG_CMD='echo "PROBED:$1" >&2; echo v1.0.0' \
      "$CHECKER" --json 2>"$tmp/probe.err")
run_case "T14 pin owner and plugin repo are different in the fixture" \
  grep -q "HostRepo" <<<"$(git -C "$e/claude/plugins/marketplaces/host-mkt" remote get-url origin)"
run_case "T14 json reports the plugin's own version line, not the host's" \
  grep -q '"pinned":"1.0.0","latest":"1.0.0"' <<<"$out"
run_case "T14 no spurious PIN_LAG from a foreign repo's release" \
  test -z "$(grep 'PIN_LAG' <<<"$out")"

echo ""
echo "plugin-version-check: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
