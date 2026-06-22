#!/usr/bin/env bash
# manifest-gate.sh — membership gate between web ingestion (A) and the semantic
# layer (B): pass a draft entry only if every fact's source is a URL that the
# web-ingest engine ACTUALLY FETCHED this session.
#
# This is the membership check the semantic layer's presence check cannot make:
# semantic_layer only asserts a `source` string exists; this asserts the source
# is in the fetch manifest. The two gates run in series — membership, then
# presence (echo entry | semantic-layer.sh record).
#
# Usage:
#   echo '{"entry":<draft>,"manifest":[<fetched-url>,...]}' | tools/manifest-gate.sh
#   echo '{"entry":<draft>,"manifest":[...]}'              | tools/manifest-gate.sh --drop
#
# STDIN : {"entry": <draft entry>, "manifest": [<fetched url>, ...]}
#         manifest = the URLs web-ingest FETCHED (index.json[].url, or a scrape /
#         crawl record's .url) — not links[], which are discovered candidates, unfetched.
# STDOUT: pass    -> the entry           (pipe to: semantic-layer.sh record)
#         fail    -> {"gaps":[...]}      (pipe to: semantic-layer.sh feedback <id>)
#         --drop  -> the survivor entry  (pipe to: semantic-layer.sh record)
#
# Exit codes: 0 pass / --drop survivor, 2 usage or malformed input,
#             3 grounding failure (>=1 ungrounded fact) — distinct from the
#             semantic layer's exit 2 so a pipeline can tell the two apart.
# Fails closed: nothing that is not provably grounded is emitted for record.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exec python3 "$REPO_ROOT/tools/manifest_gate.py" "$@"
