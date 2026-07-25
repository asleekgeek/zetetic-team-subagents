#!/usr/bin/env python3
"""Generate a CycloneDX SBOM of the release bundle's file contents (issue #53).

A conventional dependency SBOM does not fit this repo: it ships no package
lockfile — every artifact is first-party source (shell, python, markdown) that
executes in the user's session. The honest inventory is therefore a
file-component SBOM: every file the bundle delivers, with its SHA-256, so
"what is in this bundle" — including vendored third-party skill material such
as the external prior art the redaction skill cites (§8) — is enumerable and
diffable across releases.

CycloneDX 1.5, `component.type = "file"`. Standard library only.

Usage:
  gen-bundle-sbom.py --version <v> --output <path> <bundle-path> [<bundle-path> ...]
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from datetime import datetime, timezone
from pathlib import Path

_CHUNK = 1024 * 1024


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _iter_files(roots: list[str]) -> list[Path]:
    """Return every regular file under the given bundle paths, sorted.

    Precondition: each entry is a file or directory relative to CWD.
    Postcondition: a deterministic (sorted) list of file paths; directories are
    walked recursively, individual files are included as-is.
    """
    found: set[Path] = set()
    for root in roots:
        p = Path(root)
        if p.is_dir():
            found.update(f for f in p.rglob("*") if f.is_file())
        elif p.is_file():
            found.add(p)
    return sorted(found)


def build_sbom(version: str, roots: list[str]) -> dict:
    """Build the CycloneDX 1.5 document for the bundle files.

    Postcondition: returns a dict with one `file` component per bundle file,
    each carrying a SHA-256 hash; the top-level component describes the plugin.
    """
    files = _iter_files(roots)
    components = [
        {
            "type": "file",
            "name": str(f),
            "version": version,
            "hashes": [{"alg": "SHA-256", "content": _sha256(f)}],
        }
        for f in files
    ]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "timestamp": now,
            "component": {
                "type": "application",
                "name": "zetetic-team-subagents",
                "version": version,
            },
        },
        "components": components,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="plugin version")
    parser.add_argument("--output", required=True, type=Path, help="SBOM output path")
    parser.add_argument("roots", nargs="+", help="bundle paths (dirs or files)")
    args = parser.parse_args(argv)

    import json

    sbom = build_sbom(args.version, args.roots)
    args.output.write_text(json.dumps(sbom, indent=2) + "\n", encoding="utf-8")
    print(f"SBOM: {len(sbom['components'])} file components -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
