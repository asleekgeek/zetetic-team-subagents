#!/usr/bin/env python3
"""manifest_gate.py — membership gate: every fact's source must be a URL that
the web-ingest engine ACTUALLY FETCHED this session.

Single responsibility: given a draft semantic-layer entry and the manifest of
URLs that were fetched, pass the entry only if every fact is grounded in a
fetched page. This is the *membership* check that the semantic layer's
*presence* check cannot make — semantic_layer.validate_entry only asserts that a
`source` string exists (semantic_layer.py:70); it cannot tell a real fetched URL
from a plausible-but-unfetched one. The two run in series: membership here,
presence there.

It imports neither web_ingest nor semantic_layer — it is a pure stdin->stdout
filter so it can sit in any pipe. No filesystem, no network, no I/O beyond
stdin/stdout/exit.

STDIN  : {"entry": <draft entry>, "manifest": [<fetched url>, ...]}
STDOUT : pass    -> the entry           (pipe to: semantic-layer.sh record)
         fail    -> {"gaps": [...]}      (pipe to: semantic-layer.sh feedback <id>)
         --drop  -> the survivor entry   (pipe to: semantic-layer.sh record)
Exit codes: 0 pass (or --drop survivor), 2 usage/malformed input,
            3 grounding failure (>=1 ungrounded fact).

Fails closed: anything not provably grounded is rejected, not passed through.
"""
from __future__ import annotations

import argparse
import json
import sys
from urllib.parse import urlsplit

# Exit 3 is distinct from semantic_layer's exit 2 so a pipeline can tell a
# grounding failure (this gate) apart from a schema failure (the presence gate).
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_UNGROUNDED = 3

# A scheme's default port, dropped during normalization so the explicit :80/:443
# form and the implicit form ground identically.
# source: RFC 3986 §6.2.3 (Scheme-Based Normalization)
DEFAULT_PORTS = {"http": "80", "https": "443"}

# The verify-at-source step may record a source as '<url> -> "exact passage"'.
# The bare URL is everything left of this separator; ' -> ' cannot occur inside
# a valid http(s) URL (space and '>' are not permitted unencoded, RFC 3986 §2).
# source: skills/research/web-to-semantic.md (verify-at-source convention)
PROVENANCE_SEP = " -> "


def normalize_url(raw: str) -> str:
    """Canonical form of a URL reference for membership comparison.

    Per RFC 3986 §6.2: case-normalize scheme and host (§6.2.2.1), drop the
    scheme's default port (§6.2.3), and drop the fragment — a fragment is a
    secondary, client-side locator, not part of the resource (§3.5), so a fact
    citing a page section grounds against the whole page that was fetched. A
    trailing path slash is stripped (root-path equivalence §6.2.3, extended to
    sub-paths) and the project's ' -> "passage"' provenance suffix is removed
    first. Applied identically to manifest URLs and fact sources, so two
    references to the same resource compare equal. Query is retained: it
    identifies a distinct resource, so dropping it would weaken fail-closed.
    """
    bare = raw.split(PROVENANCE_SEP, 1)[0].strip()
    parts = urlsplit(bare)
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()
    netloc = host
    if parts.port is not None and str(parts.port) != DEFAULT_PORTS.get(scheme):
        netloc = f"{host}:{parts.port}"
    canonical = f"{scheme}://{netloc}{parts.path.rstrip('/')}"
    if parts.query:
        canonical += f"?{parts.query}"
    return canonical


def classify(facts: list, manifest_set: set) -> tuple[list, list]:
    """Split facts into (grounded, ungrounded) by membership in the manifest."""
    grounded: list = []
    ungrounded: list = []
    for fact in facts:
        source = fact.get("source") if isinstance(fact, dict) else None
        if source and normalize_url(source) in manifest_set:
            grounded.append(fact)
        else:
            ungrounded.append(fact)
    return grounded, ungrounded


def fact_to_gap(fact: dict) -> dict:
    """An ungrounded fact becomes an open gap — a claim still needing a fetched
    source. Schema: memory/semantic-layer.schema.yaml gaps[] {topic, description, status}."""
    source = fact.get("source") if isinstance(fact, dict) else None
    return {
        "topic": (fact.get("claim") if isinstance(fact, dict) else None) or "(no claim)",
        "description": f"ungrounded — source not in fetch manifest: {source or '(no source)'}",
        "status": "open",
    }


def gate(entry: dict, manifest: list, drop: bool) -> tuple:
    """Pure gating decision. Returns (stdout_obj_or_None, stderr_lines, exit_code)."""
    facts = entry.get("facts")
    if not isinstance(facts, list):
        return None, ["error: entry.facts must be a list"], EXIT_USAGE
    manifest_set = {normalize_url(u) for u in manifest}
    grounded, ungrounded = classify(facts, manifest_set)
    if not ungrounded:
        return entry, [], EXIT_OK

    gaps = [fact_to_gap(f) for f in ungrounded]
    stderr = [f"ungrounded: {g['topic']}  [{g['description']}]" for g in gaps]
    if not drop:
        return {"gaps": gaps}, stderr, EXIT_UNGROUNDED

    survivor = dict(entry)
    survivor["facts"] = grounded
    survivor["gaps"] = (entry.get("gaps") or []) + gaps
    if not grounded:
        stderr.append("note: every fact was dropped — survivor has no facts and "
                      "will be rejected by `semantic-layer.sh record` (fail closed)")
    return survivor, stderr, EXIT_OK


def read_payload() -> tuple[dict, list]:
    """Parse and shape-check the stdin payload. Raises ValueError on any defect."""
    raw = sys.stdin.read().strip()
    if not raw:
        raise ValueError('expected {"entry": {...}, "manifest": [...]} on stdin')
    payload = json.loads(raw)
    if not isinstance(payload, dict) or "entry" not in payload or "manifest" not in payload:
        raise ValueError('stdin must be an object with "entry" and "manifest" keys')
    if not isinstance(payload["entry"], dict) or not isinstance(payload["manifest"], list):
        raise ValueError("entry must be an object and manifest must be a list")
    return payload["entry"], payload["manifest"]


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="manifest_gate", description=__doc__)
    parser.add_argument(
        "--drop", action="store_true",
        help="move ungrounded facts to gaps[] and emit the survivor entry (exit 0) "
             "instead of failing the whole entry (exit 3)")
    args = parser.parse_args(argv)
    try:
        entry, manifest = read_payload()
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE
    stdout_obj, stderr_lines, code = gate(entry, manifest, args.drop)
    for line in stderr_lines:
        print(line, file=sys.stderr)
    if stdout_obj is not None:
        print(json.dumps(stdout_obj, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
