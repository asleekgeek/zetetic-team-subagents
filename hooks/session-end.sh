#!/usr/bin/env bash
# session-end.sh — Record session context before exit
set -euo pipefail

# Path resolution: CLAUDE_PLUGIN_ROOT → script-relative → git root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
TOOLS="${PLUGIN_ROOT}/tools"
[[ ! -d "$TOOLS" ]] && TOOLS="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tools"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Auto-save a minimal session summary
BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo 'unknown')"
LAST_COMMIT="$(git -C "$REPO_ROOT" log --oneline -1 2>/dev/null || echo 'none')"
# Guard: only count when inside a work tree, else the pipeline's git-128 would
# (under pipefail) abort the script before the session save below. Fail-open to 0.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  UNCOMMITTED="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
else
  UNCOMMITTED=0
fi

"$TOOLS/session-store.sh" save "Branch: $BRANCH | Last: $LAST_COMMIT | Uncommitted: $UNCOMMITTED files" 2>/dev/null || true

echo "Session context saved." >&2
exit 0
