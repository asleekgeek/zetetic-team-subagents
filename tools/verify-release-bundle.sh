#!/usr/bin/env bash
# verify-release-bundle.sh — reject a tampered plugin bundle BEFORE it runs.
#
# Issue #53 criterion 2. Everything this plugin ships executes in the user's
# session with the user's permissions, and there is no sandbox between a
# modified hook and the machine. Attestation nobody checks changes nothing, so
# this is the check: given the released tarball and its published checksum, it
#   1. verifies the tarball's SHA-256 against the published .sha256 BEFORE the
#      archive is unpacked — a tampered tarball never gets extracted;
#   2. after extraction, verifies every executable file (hooks/*, tools/*.sh|py)
#      against EXECUTABLE-MANIFEST.sha256 — so a swapped hook inside an
#      otherwise-valid archive is still caught before anything is run.
# Any mismatch exits non-zero; the caller must not proceed on failure.
#
# Usage:
#   tools/verify-release-bundle.sh <bundle.tar.gz> <bundle.tar.gz.sha256> \
#       [<executable-manifest.sha256>]
#
# Exit: 0 verified, 1 integrity failure (tamper), 2 usage/IO error.
set -euo pipefail

BUNDLE="${1:-}"
BUNDLE_SUM="${2:-}"
EXEC_MANIFEST="${3:-}"

if [[ -z "$BUNDLE" || -z "$BUNDLE_SUM" ]]; then
  echo "usage: $0 <bundle.tar.gz> <bundle.tar.gz.sha256> [<exec-manifest.sha256>]" >&2
  exit 2
fi
[[ -f "$BUNDLE" ]]     || { echo "error: bundle not found: $BUNDLE" >&2; exit 2; }
[[ -f "$BUNDLE_SUM" ]] || { echo "error: checksum file not found: $BUNDLE_SUM" >&2; exit 2; }

sha_tool() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

# --- 1. tarball checksum, BEFORE unpacking ---------------------------------
expected="$(awk '{print $1}' "$BUNDLE_SUM" | head -1 | tr '[:upper:]' '[:lower:]')"
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: $BUNDLE_SUM does not contain a SHA-256 digest" >&2
  exit 2
fi
actual="$(sha_tool "$BUNDLE" | tr '[:upper:]' '[:lower:]')"
if [[ "$actual" != "$expected" ]]; then
  echo "INTEGRITY FAILURE: bundle checksum mismatch" >&2
  echo "  published: $expected" >&2
  echo "  actual:    $actual" >&2
  echo "  refusing to unpack a tampered bundle." >&2
  exit 1
fi
echo "OK: bundle checksum matches ($actual)"

# --- 2. executable manifest, AFTER extraction, BEFORE execution ------------
[[ -z "$EXEC_MANIFEST" ]] && { echo "OK: no executable manifest supplied — tarball verified."; exit 0; }
[[ -f "$EXEC_MANIFEST" ]] || { echo "error: manifest not found: $EXEC_MANIFEST" >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
tar -xzf "$BUNDLE" -C "$workdir"

fail=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  want="$(awk '{print $1}' <<<"$line" | tr '[:upper:]' '[:lower:]')"
  rel="$(awk '{print $2}' <<<"$line")"
  target="$workdir/$rel"
  if [[ ! -f "$target" ]]; then
    echo "INTEGRITY FAILURE: manifested executable missing from bundle: $rel" >&2
    fail=1
    continue
  fi
  got="$(sha_tool "$target" | tr '[:upper:]' '[:lower:]')"
  if [[ "$got" != "$want" ]]; then
    echo "INTEGRITY FAILURE: executable content changed: $rel" >&2
    echo "  manifest: $want" >&2
    echo "  actual:   $got" >&2
    fail=1
  fi
done < "$EXEC_MANIFEST"

if [[ "$fail" -ne 0 ]]; then
  echo "refusing: one or more session-executing files do not match the manifest." >&2
  exit 1
fi
echo "OK: all $(grep -c . "$EXEC_MANIFEST") executable files match the manifest."
exit 0
