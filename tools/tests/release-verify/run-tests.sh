#!/usr/bin/env bash
# Regression tests for tools/verify-release-bundle.sh (issue #53 criterion 2).
#
# The point of the verifier is that a TAMPERED bundle is REJECTED before it can
# run — asserting only that a good bundle passes would miss the entire reason
# it exists (§13 A3, G4). The load-bearing cases here are therefore (b)-(d):
#   (a) an intact bundle + matching checksum + matching manifest -> exit 0
#   (b) a tampered TARBALL (checksum mismatch) -> exit 1, refused BEFORE unpack
#   (c) a swapped executable inside an otherwise-valid tarball -> exit 1
#   (d) a manifested executable removed from the bundle -> exit 1
#   (e) a malformed checksum file -> exit 2 (refuse, do not guess)
set -euo pipefail
cd "$(dirname "$0")"
VERIFY="../../verify-release-bundle.sh"

PASS=0
FAIL=0
check() { # name expected_code actual_code [grep_pattern] [output]
  local name="$1" ec="$2" ac="$3" pat="${4:-}" out="${5:-}" ok=1
  if [[ "$ac" != "$ec" ]]; then ok=0; echo "  FAIL: $name — exit expected $ec got $ac"; fi
  if [[ -n "$pat" ]] && ! grep -q "$pat" <<<"$out"; then
    ok=0; echo "  FAIL: $name — output missing /$pat/"
  fi
  if [[ "$ok" == 1 ]]; then echo "  PASS: $name"; PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
sha() { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- build an intact fixture bundle ---------------------------------------
SRC="$WORK/src"
mkdir -p "$SRC/hooks" "$SRC/tools"
printf '#!/usr/bin/env bash\necho authentic-hook\n' > "$SRC/hooks/session-start.sh"
printf '#!/usr/bin/env bash\necho authentic-tool\n' > "$SRC/tools/gate.sh"
BUNDLE="$WORK/bundle.tar.gz"
tar -czf "$BUNDLE" -C "$SRC" hooks tools
sha "$BUNDLE" > "$WORK/bundle.tar.gz.sha256.raw"
echo "$(cat "$WORK/bundle.tar.gz.sha256.raw")  bundle.tar.gz" > "$WORK/bundle.tar.gz.sha256"
# manifest of executables, paths relative to the extraction root
MAN="$WORK/EXECUTABLE-MANIFEST.sha256"
( cd "$SRC" && for f in hooks/session-start.sh tools/gate.sh; do echo "$(sha "$f")  $f"; done ) > "$MAN"

# (a) intact -> 0
OUT="$(bash "$VERIFY" "$BUNDLE" "$WORK/bundle.tar.gz.sha256" "$MAN" 2>&1)"; CODE=$?
check "intact bundle verifies" 0 "$CODE" "match the manifest" "$OUT"

# (b) tampered tarball -> 1, refused before unpack
BAD_TAR="$WORK/tampered.tar.gz"
printf '#!/usr/bin/env bash\necho KEYLOGGER\n' > "$SRC/hooks/session-start.sh"
tar -czf "$BAD_TAR" -C "$SRC" hooks tools   # different bytes, same published sha
set +e
OUT="$(bash "$VERIFY" "$BAD_TAR" "$WORK/bundle.tar.gz.sha256" "$MAN" 2>&1)"; CODE=$?
set -e
check "tampered tarball rejected before unpack" 1 "$CODE" "refusing to unpack" "$OUT"

# (c) valid tarball, but a swapped executable vs the manifest -> 1
#     rebuild checksum for the tampered archive so the tarball check passes and
#     the manifest check is what must catch the swap.
sha "$BAD_TAR" > /dev/null
echo "$(sha "$BAD_TAR")  bundle.tar.gz" > "$WORK/tampered.sha256"
set +e
OUT="$(bash "$VERIFY" "$BAD_TAR" "$WORK/tampered.sha256" "$MAN" 2>&1)"; CODE=$?
set -e
check "swapped executable rejected by manifest" 1 "$CODE" "executable content changed" "$OUT"

# (d) manifested file removed from bundle -> 1
MISS_SRC="$WORK/miss"; mkdir -p "$MISS_SRC/tools"
printf '#!/usr/bin/env bash\necho x\n' > "$MISS_SRC/tools/gate.sh"   # hooks/ dropped
MISS_TAR="$WORK/miss.tar.gz"
tar -czf "$MISS_TAR" -C "$MISS_SRC" tools
echo "$(sha "$MISS_TAR")  bundle.tar.gz" > "$WORK/miss.sha256"
set +e
OUT="$(bash "$VERIFY" "$MISS_TAR" "$WORK/miss.sha256" "$MAN" 2>&1)"; CODE=$?
set -e
check "missing manifested executable rejected" 1 "$CODE" "missing from bundle" "$OUT"

# (e) malformed checksum file -> 2
echo "not-a-digest  bundle.tar.gz" > "$WORK/malformed.sha256"
set +e
OUT="$(bash "$VERIFY" "$BUNDLE" "$WORK/malformed.sha256" "$MAN" 2>&1)"; CODE=$?
set -e
check "malformed checksum refused" 2 "$CODE" "does not contain a SHA-256" "$OUT"

echo ""
echo "release-verify: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
