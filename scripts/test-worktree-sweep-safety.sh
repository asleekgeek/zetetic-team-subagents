#!/usr/bin/env bash
# test-worktree-sweep-safety.sh — Regression test for issue #33: sweep must
# never remove a freshly-created worktree, and must still remove genuinely
# stale merged ones.
#
# Root cause (issue #33): `git merge-base --is-ancestor <branch>
# origin/main` returns TRUE for a brand-new branch with zero commits (its
# tip equals origin/main's tip). Combined with a clean working tree (true
# before the agent's first edit), the old sweep logic classified an
# untouched, minutes-old worktree as "merged + clean" and removed it.
#
# Tests:
#   P1  Fresh worktree (0 commits, clean, /tmp path) survives a sweep run
#       within the grace period — proves the fix closes the race.
#   P2  A worktree older than the grace period, still merged + clean, IS
#       removed and deregistered — proves the fix does not disable cleanup.
#   P3  A worktree outside /tmp (deliberate location) is never touched
#       regardless of age or merge state.
#
# Invariants tested:
#   - Directory + `git worktree list` registration both survive P1.
#   - Directory + `git worktree list` registration both gone after P2.
#   - P3's worktree is untouched in both directory and registration.

set -euo pipefail

REPO="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
MANAGER="$REPO/tools/worktree-manager.sh"

TMP="$(mktemp -d)"
# A second scratch root guaranteed OUTSIDE /tmp and /private/tmp, for P3.
# `mktemp -d`'s default TMPDIR is platform-dependent (/tmp on Linux CI
# runners, but $TMPDIR under /var/folders on macOS) — using it directly for
# a "deliberate, non-tmp" fixture is not portable. Root it under $HOME
# instead, which is never under /tmp on either platform.
NONTMP_ROOT="$(mktemp -d "${HOME}/.zts-sweep-test-XXXXXX")"
TARGET=""
cleanup() {
  if [[ -n "$TARGET" ]]; then
    git -C "$TARGET" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree/ {print $2}' | grep -v "^$TARGET\$" \
      | xargs -I{} git -C "$TARGET" worktree remove --force {} 2>/dev/null || true
  fi
  rm -rf "$TMP" "$NONTMP_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; (( PASS_COUNT++ )) || true; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; (( FAIL_COUNT++ )) || true; }

# Throwaway target repo with an `origin/main` remote-tracking ref, since
# sweep_worktrees requires origin/main to exist locally.
TARGET="$TMP/target"
mkdir -p "$TARGET"
git -C "$TARGET" init -q -b main
# Local-only identity: CI runners carry no global git user.name/user.email,
# and this repo must not depend on one existing.
git -C "$TARGET" config user.email "test@example.invalid"
git -C "$TARGET" config user.name "Worktree Sweep Test"
git -C "$TARGET" commit -q --allow-empty -m init
git -C "$TARGET" update-ref refs/remotes/origin/main refs/heads/main
git -C "$TARGET" remote add origin "$TARGET" 2>/dev/null || true

AUDIT_LOG="$TMP/audit.log"

# ── P1: fresh worktree survives within grace period ─────────────────────────
echo "P1: fresh worktree (0 commits, clean) survives a sweep within grace period"
FRESH="/tmp/zts-sweep-test-fresh-$$"
rm -rf "$FRESH"
git -C "$TARGET" worktree add -q "$FRESH" -b test/fresh origin/main
WORKTREE_AUDIT_LOG="$AUDIT_LOG" WORKTREE_GRACE_SECONDS=3600 \
  "$MANAGER" sweep "$TARGET" >/dev/null 2>&1 || true
if [[ -d "$FRESH" ]]; then pass "directory still present"; else fail "directory removed"; fi
if git -C "$TARGET" worktree list | grep -q "$FRESH"; then
  pass "still registered in git worktree list"
else
  fail "deregistered from git worktree list"
fi
git -C "$TARGET" worktree remove --force "$FRESH" 2>/dev/null || true
git -C "$TARGET" branch -D test/fresh 2>/dev/null || true

# ── P2: stale merged worktree IS removed (grace period elapsed) ─────────────
echo "P2: stale merged+clean worktree is removed once past grace period"
STALE="/tmp/zts-sweep-test-stale-$$"
rm -rf "$STALE"
git -C "$TARGET" worktree add -q "$STALE" -b test/stale origin/main
WORKTREE_AUDIT_LOG="$AUDIT_LOG" WORKTREE_GRACE_SECONDS=0 \
  "$MANAGER" sweep "$TARGET" >/dev/null 2>&1 || true
if [[ ! -d "$STALE" ]]; then pass "directory removed"; else fail "directory still present"; rm -rf "$STALE"; fi
if git -C "$TARGET" worktree list | grep -q "$STALE"; then
  fail "still registered in git worktree list"
else
  pass "deregistered from git worktree list"
fi

# ── P3: non-tmp worktree is never touched ────────────────────────────────────
echo "P3: worktree outside /tmp is never removed regardless of age/merge state"
DELIBERATE="$NONTMP_ROOT/deliberate-wt"
git -C "$TARGET" worktree add -q "$DELIBERATE" -b test/deliberate origin/main
WORKTREE_AUDIT_LOG="$AUDIT_LOG" WORKTREE_GRACE_SECONDS=0 \
  "$MANAGER" sweep "$TARGET" >/dev/null 2>&1 || true
if [[ -d "$DELIBERATE" ]]; then pass "directory still present"; else fail "directory removed"; fi
if git -C "$TARGET" worktree list | grep -q "$DELIBERATE"; then
  pass "still registered in git worktree list"
else
  fail "deregistered from git worktree list"
fi
git -C "$TARGET" worktree remove --force "$DELIBERATE" 2>/dev/null || true
git -C "$TARGET" branch -D test/deliberate 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
