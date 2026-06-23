#!/usr/bin/env bash
# pre-push-review.sh — Check for zetetic violations before push
set -euo pipefail

# Command guard: only fire on git push
HOOK_INPUT=""
if ! [ -t 0 ]; then
  # Portable bounded stdin read. macOS ships NO 'timeout'/'gtimeout'; its
  # absence must NOT zero out the payload (that silently disables the hook — the
  # root cause of audit finding R1). Use the bound if present, else plain cat.
  _ZT="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$_ZT" ]; then
    HOOK_INPUT="$("$_ZT" 3 cat 2>/dev/null || true)"
  else
    HOOK_INPUT="$(cat 2>/dev/null || true)"
  fi
fi
if command -v jq &>/dev/null; then
  BASH_CMD=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
else
  BASH_CMD=$(echo "$HOOK_INPUT" | grep -oE '"command":\s*"[^"]*"' 2>/dev/null | head -1 | sed 's/.*"command":\s*"//' | sed 's/"$//' || echo "")
fi
# A7: match the git 'push' subcommand at a command position (line start or after
# a shell separator), allowing global flags (e.g. `git -C /path push`), and the
# verb as a whole word not followed by '-' (excludes hypothetical push-* verbs).
# This avoids false-triggering on quoted strings, --grep= values, and grep args.
GIT_PUSH_RE='(^|[;&|({])[[:space:]]*((sudo|command|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|({]*/)?git[[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*push([[:space:];&|)<>]|$)'
if ! echo "$BASH_CMD" | grep -qE "$GIT_PUSH_RE" 2>/dev/null; then exit 0; fi

# Path resolution: CLAUDE_PLUGIN_ROOT → script-relative → git root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
TOOLS="${PLUGIN_ROOT}/tools"
[[ ! -d "$TOOLS" ]] && TOOLS="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tools"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Graceful degradation: if tools don't exist, skip checks
if [[ ! -x "$TOOLS/zetetic-checker.sh" ]]; then
  echo "WARNING: zetetic-checker.sh not found — skipping pre-push checks." >&2
  exit 0
fi

TRACKING="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo '')"
[[ -z "$TRACKING" ]] && exit 0

CHANGED_FILES=()
while IFS= read -r f; do
  [[ -f "$REPO_ROOT/$f" ]] && CHANGED_FILES+=("$REPO_ROOT/$f")
done < <(git -C "$REPO_ROOT" diff "$TRACKING"...HEAD --name-only 2>/dev/null)

[[ ${#CHANGED_FILES[@]} -eq 0 ]] && exit 0

"$TOOLS/zetetic-checker.sh" --files "${CHANGED_FILES[@]}" 2>&1 || {
  echo "BLOCKED: Zetetic violations in files being pushed." >&2
  exit 2
}

# Craftsmanship gate (B4): coding-standards §4 sizes + select structural rules
# on the files being pushed. Block ONLY on real violations (rc=1); fail OPEN on
# a checker/config error so a malformed .craftsmanship.conf never blocks a push.
if [[ -x "$TOOLS/craftsmanship-checker.sh" ]]; then
  craft_rc=0
  craft_output=$("$TOOLS/craftsmanship-checker.sh" --files "${CHANGED_FILES[@]}" 2>&1) || craft_rc=$?
  if [[ $craft_rc -eq 1 ]]; then
    echo "BLOCKED: Craftsmanship violations (coding-standards §4) in files being pushed." >&2
    echo "$craft_output" >&2
    exit 2
  elif [[ $craft_rc -ne 0 ]]; then
    echo "WARNING: craftsmanship-checker error (rc=$craft_rc) — skipping (fail-open)." >&2
    echo "$craft_output" >&2
  fi
fi

"$TOOLS/difficulty-book-manager.sh" check 2>&1 || {
  echo "WARNING: Pushing with unaddressed difficulty-book entries." >&2
}

exit 0
