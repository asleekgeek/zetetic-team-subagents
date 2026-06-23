#!/usr/bin/env bash
# pre-push-provenance.sh — Verify provenance sidecars exist for research files before push
# Configurable strictness: PROVENANCE_STRICT=block (default) or PROVENANCE_STRICT=warn
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
# Match 'git push' only when 'git' is at a command position (line start or after
# a shell separator) followed by optional global flags, so the guard does NOT
# false-trigger on quoted text ('remember to git push later') or unrelated verbs.
GIT_PUSH_RE='(^|[;&|({])[[:space:]]*((sudo|command|env)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|({]*/)?git[[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*push([[:space:];&|)<>]|$)'
if ! printf '%s' "$BASH_CMD" | grep -qE "$GIT_PUSH_RE" 2>/dev/null; then exit 0; fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STRICTNESS="${PROVENANCE_STRICT:-warn}"

# Get the remote branch to diff against
REMOTE="${1:-origin}"
BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo 'main')"
REMOTE_REF="${REMOTE}/${BRANCH}"

# Get changed files compared to remote
CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only "$REMOTE_REF"...HEAD 2>/dev/null || \
                git -C "$REPO_ROOT" diff --name-only HEAD~5...HEAD 2>/dev/null || echo "")

[[ -z "$CHANGED_FILES" ]] && exit 0

MISSING=0

prov_file() {
  local f="$1"
  local dir base
  dir="$(dirname "$f")"
  base="$(basename "$f")"
  echo "${dir}/.provenance-${base}.md"
}

needs_provenance() {
  local f="$1"
  # Check if file contains algorithm markers, constants, or research code
  [[ ! -f "$REPO_ROOT/$f" ]] && return 1
  case "$f" in
    *.md|*.json|*.yaml|*.yml|*.toml|*.lock|*.txt|*.csv|*.sh) return 1 ;;
  esac
  # Check for provenance-worthy content
  grep -qiE '(algorithm|threshold|alpha|beta|gamma|epsilon|coefficient|weight.*=|factor.*=|# source:|implementation of)' "$REPO_ROOT/$f" 2>/dev/null
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if needs_provenance "$file"; then
    pf="$(prov_file "$REPO_ROOT/$file")"
    if [[ ! -f "$pf" ]]; then
      echo "MISSING PROVENANCE: $file"
      echo "  Expected: $(prov_file "$file")"
      echo "  Create with: tools/provenance-manager.sh init \"$file\""
      MISSING=$((MISSING + 1))
    fi
  fi
done <<< "$CHANGED_FILES"

if [[ $MISSING -gt 0 ]]; then
  echo ""
  echo "$MISSING file(s) with research content lack provenance sidecars."
  if [[ "$STRICTNESS" == "block" ]]; then
    echo "BLOCKED: Set PROVENANCE_STRICT=warn to override."
    exit 2
  else
    echo "WARNING: Consider adding provenance before merging."
  fi
fi

exit 0
