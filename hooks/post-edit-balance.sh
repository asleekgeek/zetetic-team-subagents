#!/usr/bin/env bash
# post-edit-balance.sh — After editing data pipeline files, remind about conservation checks
set -euo pipefail

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

# Extract file path: jq-primary, grep-fallback (matches pre-tool-claim-gate.sh:14-18)
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
else
  FILE_PATH=$(echo "$HOOK_INPUT" | grep -oE '"file_path":\s*"[^"]*"' 2>/dev/null | head -1 | sed 's/.*"file_path":\s*"//' | sed 's/"$//' || echo "")
fi

[[ -z "$FILE_PATH" ]] && exit 0

# Check if the edited file is in a data pipeline path
if echo "$FILE_PATH" | grep -qiE '(migration|pipeline|etl|transform|ingest|export)' 2>/dev/null; then
  echo "NOTE: Edited a data pipeline file. Run /balance to verify conservation (inputs = outputs)." >&2
fi

exit 0
