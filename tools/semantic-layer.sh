#!/usr/bin/env bash
# semantic-layer.sh — query-indexed semantic layer over Cortex memory.
#
# A human+AI-readable table of contents keyed by query. Records what we know
# about a topic (facts+sources+gaps), so agents recall before re-ingesting and
# get better on each visit. Full content lives in Cortex; this indexes it.
#
# Usage:
#   tools/semantic-layer.sh init
#   tools/semantic-layer.sh query "<topic or question>" [--json]
#   echo '<entry-json>'    | tools/semantic-layer.sh record
#   echo '<feedback-json>' | tools/semantic-layer.sh feedback <query_id>
#   tools/semantic-layer.sh revalidate [--json]
#   tools/semantic-layer.sh validate
#
# record stdin  : a full entry object (see memory/semantic-layer.schema.yaml).
#                 The agent first calls cortex remember, then passes the returned
#                 id in facts[].cortex_id / pointers.cortex_memories here.
# feedback stdin: { "outcome": {...}, "gaps": [...], "status": "stale" }
#
# Exit codes: 0 success, 1 runtime error, 2 usage/validation error.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LAYER_FILE="${SEMANTIC_LAYER_FILE:-$REPO_ROOT/memory/semantic-layer.yaml}"
PYTHON_MODULE="$REPO_ROOT/tools/semantic_layer.py"

ACTION="${1:-}"
[[ -z "$ACTION" ]] && {
  echo "usage: $0 <init|query|record|feedback|revalidate|validate> [args]" >&2
  exit 2
}
shift

exec python3 "$PYTHON_MODULE" --file "$LAYER_FILE" "$ACTION" "$@"
