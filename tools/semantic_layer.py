#!/usr/bin/env python3
"""semantic_layer.py — data layer for the query-indexed semantic layer.

Owns all YAML I/O, validation, query matching, and upsert logic for
memory/semantic-layer.yaml. The thin CLI (tools/semantic-layer.sh) dispatches
here; this module never touches Cortex — the calling agent owns the Cortex
write and passes the resulting cortex_id in as a pointer (YAML indexes Cortex).

Contract documented in memory/semantic-layer.schema.yaml; the rules below are
the executable enforcement of that contract.

Exit codes: 0 success, 1 runtime error, 2 usage/validation error.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys
from pathlib import Path

import yaml

# --- contract (mirror of semantic-layer.schema.yaml; single source of the checks) ---
INTENTS = {"ingest", "verify", "compare", "monitor"}
STATUSES = {"fresh", "stale", "superseded"}
ENTRY_REQUIRED = ("query", "query_id", "intent", "domain", "status", "summary", "facts")
SCHEMA_VERSION = 1


def today() -> str:
    return datetime.date.today().isoformat()


# --- persistence -----------------------------------------------------------
def load(path: Path) -> dict:
    """Return the parsed file, or a fresh empty document if absent."""
    if not path.exists():
        return {"version": SCHEMA_VERSION, "entries": []}
    data = yaml.safe_load(path.read_text()) or {}
    data.setdefault("version", SCHEMA_VERSION)
    data.setdefault("entries", [])
    return data


def save(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=100)
    )


# --- validation ------------------------------------------------------------
def validate_entry(entry: dict) -> list[str]:
    """Return a list of human-readable contract violations (empty == valid)."""
    errors: list[str] = []
    for field in ENTRY_REQUIRED:
        if not entry.get(field):
            errors.append(f"missing required field: {field}")
    if entry.get("intent") and entry["intent"] not in INTENTS:
        errors.append(f"intent must be one of {sorted(INTENTS)}")
    if entry.get("status") and entry["status"] not in STATUSES:
        errors.append(f"status must be one of {sorted(STATUSES)}")
    for i, fact in enumerate(entry.get("facts") or []):
        if not isinstance(fact, dict):
            errors.append(f"facts[{i}] must be a mapping")
            continue
        if not fact.get("claim"):
            errors.append(f"facts[{i}] missing claim")
        if not fact.get("source"):  # zetetic source discipline §8
            errors.append(f"facts[{i}] missing source (no source -> not stored)")
    return errors


def validate_file(data: dict) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()
    for entry in data.get("entries", []):
        qid = entry.get("query_id", "<no-id>")
        if qid in seen:
            errors.append(f"duplicate query_id: {qid}")
        seen.add(qid)
        errors.extend(f"[{qid}] {e}" for e in validate_entry(entry))
    return errors


# --- query matching --------------------------------------------------------
def find(data: dict, query_id: str) -> dict | None:
    for entry in data.get("entries", []):
        if entry.get("query_id") == query_id:
            return entry
    return None


def match(data: dict, text: str) -> list[dict]:
    """Case-insensitive substring match over query, query_id, and aliases."""
    needle = text.strip().lower()
    hits: list[dict] = []
    for entry in data.get("entries", []):
        haystack = [entry.get("query", ""), entry.get("query_id", "")]
        haystack.extend(entry.get("aliases", []) or [])
        if any(needle in h.lower() for h in haystack):
            hits.append(entry)
    return hits


# --- mutation --------------------------------------------------------------
def upsert(data: dict, entry: dict) -> str:
    """Insert or replace an entry by query_id. Returns 'created' or 'updated'."""
    entry["updated"] = today()
    existing = find(data, entry["query_id"])
    if existing is None:
        entry.setdefault("created", today())
        data["entries"].append(entry)
        return "created"
    entry["created"] = existing.get("created", today())  # preserve first-write date
    existing.update(entry)
    return "updated"


def apply_feedback(entry: dict, fb: dict) -> None:
    """Fold an outcome/gaps feedback record onto an existing entry."""
    if "outcome" in fb:
        entry["outcome"] = fb["outcome"]
    if "gaps" in fb:
        entry.setdefault("gaps", [])
        entry["gaps"].extend(fb["gaps"])
    if fb.get("status"):
        entry["status"] = fb["status"]
    entry["updated"] = today()


def stale_entries(data: dict) -> list[dict]:
    """Entries marked stale/superseded or past their revalidate_after date."""
    out: list[dict] = []
    now = today()
    for entry in data.get("entries", []):
        if entry.get("status") in ("stale", "superseded"):
            out.append(entry)
            continue
        rev = (entry.get("freshness") or {}).get("revalidate_after")
        if rev and str(rev) <= now:
            out.append(entry)
    return out


# --- rendering -------------------------------------------------------------
def render(entry: dict) -> str:
    lines = [f"## {entry.get('query', '(no query)')}  [{entry.get('query_id')}]"]
    lines.append(f"   status={entry.get('status')} intent={entry.get('intent')} "
                 f"domain={entry.get('domain')} updated={entry.get('updated')}")
    if entry.get("summary"):
        lines.append(f"   summary: {entry['summary'].strip()}")
    for fact in entry.get("facts") or []:
        lines.append(f"   - {fact.get('claim')}  [{fact.get('source')}]")
    gaps = [g for g in (entry.get("gaps") or []) if g.get("status") != "closed"]
    for gap in gaps:
        lines.append(f"   ! gap: {gap.get('topic')} ({gap.get('status', 'open')})")
    ptr = entry.get("pointers") or {}
    if ptr.get("cortex_memories"):
        lines.append(f"   -> cortex: {', '.join(ptr['cortex_memories'])}")
    return "\n".join(lines)


# --- CLI -------------------------------------------------------------------
def read_stdin_json() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit("error: expected a JSON object on stdin")
    return json.loads(raw)


def cmd_init(path: Path, _args) -> int:
    if path.exists():
        print(f"already exists: {path}")
        return 0
    save(path, {"version": SCHEMA_VERSION, "entries": []})
    print(f"initialized: {path}")
    return 0


def cmd_query(path: Path, args) -> int:
    hits = match(load(path), args.text)
    if args.json:
        print(json.dumps(hits, indent=2))
        return 0
    if not hits:
        print(f"(no semantic-layer entry matches '{args.text}')")
        return 0
    print("\n\n".join(render(h) for h in hits))
    return 0


def cmd_record(path: Path, _args) -> int:
    entry = read_stdin_json()
    errors = validate_entry(entry)
    if errors:
        print("validation failed:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 2
    data = load(path)
    action = upsert(data, entry)
    save(path, data)
    print(f"{action}: {entry['query_id']}")
    return 0


def cmd_feedback(path: Path, args) -> int:
    data = load(path)
    entry = find(data, args.query_id)
    if entry is None:
        print(f"error: no entry with query_id '{args.query_id}'", file=sys.stderr)
        return 2
    apply_feedback(entry, read_stdin_json())
    save(path, data)
    print(f"feedback applied: {args.query_id}")
    return 0


def cmd_revalidate(path: Path, args) -> int:
    stale = stale_entries(load(path))
    if args.json:
        print(json.dumps(stale, indent=2))
        return 0
    if not stale:
        print("(nothing to revalidate)")
        return 0
    print("Entries needing revalidation:")
    print("\n\n".join(render(e) for e in stale))
    return 0


def cmd_validate(path: Path, _args) -> int:
    errors = validate_file(load(path))
    if errors:
        print("INVALID:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 2
    print("valid")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="semantic_layer")
    parser.add_argument("--file", required=True, help="path to semantic-layer.yaml")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").set_defaults(func=cmd_init)
    q = sub.add_parser("query")
    q.add_argument("text")
    q.add_argument("--json", action="store_true")
    q.set_defaults(func=cmd_query)
    sub.add_parser("record").set_defaults(func=cmd_record)
    f = sub.add_parser("feedback")
    f.add_argument("query_id")
    f.set_defaults(func=cmd_feedback)
    r = sub.add_parser("revalidate")
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=cmd_revalidate)
    sub.add_parser("validate").set_defaults(func=cmd_validate)
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(Path(args.file), args)
    except (yaml.YAMLError, json.JSONDecodeError) as exc:
        print(f"error: malformed input — {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
