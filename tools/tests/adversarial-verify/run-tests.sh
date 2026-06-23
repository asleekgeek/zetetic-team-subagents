#!/usr/bin/env bash
# Regression tests for the adversarial-verify workflow's deterministic synthesis core
# (.claude/workflows/adversarial-verify.js). The agent lenses are non-deterministic and
# are not unit-tested (repo precedent: workflows aren't unit-tested); this pins the
# fail-closed verdict logic, including the WF-0.2 proof that an UNSOURCED-class finding
# reproduces a blocking verdict. Requires node (already a repo dependency for workflows).
set -euo pipefail
cd "$(dirname "$0")"
command -v node >/dev/null 2>&1 || { echo "adversarial-verify tests: node not found" >&2; exit 3; }
exec node core.test.mjs
