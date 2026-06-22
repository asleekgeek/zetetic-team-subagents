#!/usr/bin/env bash
# session-start-research.sh — Load research-specific context at session start
# Extension to session-start.sh for active research sessions.
set -euo pipefail

# Path resolution: CLAUDE_PLUGIN_ROOT → script-relative → git root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
TOOLS="${PLUGIN_ROOT}/tools"
[[ ! -d "$TOOLS" ]] && TOOLS="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tools"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SESSION_FILE="$REPO_ROOT/research/.session.json"
NOTEBOOK="$REPO_ROOT/research/NOTEBOOK.md"

echo "=== Research Context ==="
echo ""

# Check for active research session
if [[ -f "$SESSION_FILE" ]]; then
  echo "## Active Research Session"
  "$TOOLS/research-session-manager.sh" status 2>/dev/null || echo "(session file exists but could not read status)"
  echo ""
else
  echo "No active research session. Start one with: /research-session start \"<question>\""
  echo ""
fi

# Lab notebook status
if [[ -f "$NOTEBOOK" ]]; then
  entry_count=$(grep -c '^## [0-9]' "$NOTEBOOK" 2>/dev/null || echo 0)
  last_entry=$(grep '^## [0-9]' "$NOTEBOOK" 2>/dev/null | tail -1 | sed 's/^## //' || echo "none")
  echo "## Lab Notebook"
  echo "Entries: $entry_count"
  echo "Last entry: $last_entry"
  echo ""
else
  echo "## Lab Notebook"
  echo "No notebook found. Will be created with research session."
  echo ""
fi

# Provenance files
prov_count=$(find "$REPO_ROOT" -name '.provenance-*.md' -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [[ "$prov_count" -gt 0 ]]; then
  echo "## Provenance Files"
  echo "Active provenance sidecars: $prov_count"
  "$TOOLS/provenance-manager.sh" list 2>/dev/null | head -5 || true
  [[ "$prov_count" -gt 5 ]] && echo "  ... and $((prov_count - 5)) more"
  echo ""
fi

# Difficulty books with research context
echo "## Research Difficulty Books"
"$TOOLS/difficulty-book-manager.sh" status 2>/dev/null || echo "(none)"
echo ""

# Semantic layer: query-indexed topic memory (recall before re-ingesting)
LAYER_FILE="$REPO_ROOT/memory/semantic-layer.yaml"
if [[ -f "$LAYER_FILE" && -x "$TOOLS/semantic-layer.sh" ]]; then
  entry_count=$(grep -c '^  query_id:' "$LAYER_FILE" 2>/dev/null || true)
  echo "## Semantic Layer"
  echo "Indexed topics: ${entry_count:-0}"
  echo "Recall before ingesting a topic: tools/semantic-layer.sh query \"<topic>\""
  stale=$("$TOOLS/semantic-layer.sh" revalidate 2>/dev/null | grep -c '^## ' || true)
  [[ "${stale:-0}" -gt 0 ]] && echo "Topics needing revalidation: $stale (run: tools/semantic-layer.sh revalidate)"
  echo ""
fi

echo "Reminder: use /research-session resume to reload full context with Cortex."
