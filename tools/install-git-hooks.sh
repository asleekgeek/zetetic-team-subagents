#!/usr/bin/env bash
# install-git-hooks.sh — point this clone's git hooks at the versioned .githooks/.
#
# Run once after cloning. Git does not auto-trust a versioned hooks directory
# (a clone could otherwise execute arbitrary committed code), so each contributor
# opts in explicitly by running this. Idempotent.
#
# What it does: `git config core.hooksPath .githooks` so `git commit` runs
# .githooks/pre-commit — the native zetetic + craftsmanship commit gate.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if [[ ! -d .githooks ]]; then
  echo "ERROR: .githooks/ not found at repo root ($REPO_ROOT)." >&2
  exit 1
fi

chmod +x .githooks/* 2>/dev/null || true
git config core.hooksPath .githooks

echo "Installed: core.hooksPath -> .githooks"
echo "Active hooks:"
for h in .githooks/*; do
  [[ -f "$h" ]] && echo "  - $(basename "$h")"
done
echo "Commit gate is now live for this clone (zetetic + craftsmanship, --staged)."
