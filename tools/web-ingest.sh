#!/usr/bin/env bash
# web-ingest.sh — self-hosted web ingestion engine (Firecrawl-shaped, owned).
#
# Dependency-free (stdlib Python only). Respects robots.txt. Caches fetches so
# revisiting a topic is incremental. Standalone: emits markdown/JSON; does NOT
# write the semantic layer.
#
# Usage:
#   tools/web-ingest.sh scrape <url> [--full] [--max-age N] [--out DIR]
#   tools/web-ingest.sh map    <url> [--search TXT] [--limit N] [--subdomains]
#   tools/web-ingest.sh crawl  <url> [--depth N] [--limit N] [--full] [--out DIR]
#
# scrape : one URL -> main-content markdown (+ title, links). Default stdout JSON.
# map    : discover same-site URLs via sitemap.xml, falling back to on-page links.
# crawl  : BFS scrape bounded by --depth and --limit (polite delay between fetches).
#
# Not provided (by design): web search (not self-hostable — use WebSearch) and
# LLM extraction (the agent extracts from the returned markdown).
#
# Cache dir: $WEB_INGEST_CACHE or ./.web-ingest-cache
# Exit codes: 0 success, 1 runtime/network error, 2 usage error.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TOOLS="$REPO_ROOT/tools"

ACTION="${1:-}"
[[ -z "$ACTION" ]] && {
  echo "usage: $0 <scrape|map|crawl> <url> [options]" >&2
  exit 2
}

exec env PYTHONPATH="$TOOLS" python3 "$TOOLS/web_ingest.py" "$@"
