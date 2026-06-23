#!/usr/bin/env bash
# notification-handler.sh — Handle subagent/background task completion
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Read notification from stdin
NOTIFICATION=""
if ! [ -t 0 ]; then
  # Portable bounded stdin read. macOS ships NO 'timeout'/'gtimeout'; its
  # absence must NOT zero out the payload (that silently disables the hook — the
  # root cause of audit finding R1). Use the bound if present, else plain cat.
  _ZT="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$_ZT" ]; then
    NOTIFICATION="$("$_ZT" 3 cat 2>/dev/null || true)"
  else
    NOTIFICATION="$(cat 2>/dev/null || true)"
  fi
fi

# Log the notification
echo "=== Agent Task Completed ===" >&2
echo "$NOTIFICATION" | head -5 >&2

# Check for unmerged agent worktrees. Use 'grep -c' (single counter, no 'wc'
# pipe) and '|| true' so that grep's exit-1 on zero matches does not propagate
# under 'set -o pipefail' and corrupt ACTIVE. Default an empty result to zero so
# the arithmetic test below never sees a non-numeric value.
ACTIVE="$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "agent/" || true)"
[ -z "$ACTIVE" ] && ACTIVE=0
if [[ "$ACTIVE" -gt 0 ]]; then
  echo "Active agent worktrees: $ACTIVE (run /agent-status for details)" >&2
fi

exit 0
