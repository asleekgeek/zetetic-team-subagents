#!/usr/bin/env bash
# acceptance-gate.sh — deterministic whole-task acceptance gate for the
# autonomous build loop. Runs a configured set of command gates (zetetic-checker,
# test suites, contract-derived shell checks), aggregates their EXIT CODES, and
# returns an accept/reject verdict. No model judgement — a gate passes iff its
# command exits 0. This is what keeps the loop's convergence decision EXTERNAL
# (arXiv:2310.01798); the agent reviewers + residual compare-to-contract live in
# the controlling workflow and build on this verdict.
#
# Usage:
#   tools/acceptance-gate.sh [--config FILE] [--timeout SECONDS]
#
# --config : gate-config YAML (default: memory/acceptance-gates.yaml). Schema in
#            that file's header. The loop appends contract-derived checks to it.
#
# STDOUT  : verdict JSON {accepted, summary, gates[], unmet[]}.
# Exit codes: 0 accepted, 3 rejected (>=1 mandatory gate failed, or none
#             configured), 2 usage/config error.
# Fails closed: an empty or unreadable gate set is a rejection, not an accept.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${ACCEPTANCE_GATES_FILE:-$REPO_ROOT/memory/acceptance-gates.yaml}"

# Allow an explicit --config to override the env/default without re-parsing here:
# pass everything through, but inject the default --config when none is given.
case " $* " in
  *" --config "*) exec python3 "$REPO_ROOT/tools/acceptance_gate.py" --root "$REPO_ROOT" "$@" ;;
  *)              exec python3 "$REPO_ROOT/tools/acceptance_gate.py" --root "$REPO_ROOT" --config "$CONFIG" "$@" ;;
esac
