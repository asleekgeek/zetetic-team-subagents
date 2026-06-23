#!/usr/bin/env python3
"""stop-acceptance-gate.py — Stop hook: the real-exec acceptance gate.

When an autonomous build run is active (a ``.abl-gate.json`` marker exists in the
repo root), this hook runs the REAL acceptance gate (``tools/acceptance-gate.sh``)
as a genuine subprocess, reads its real exit code, and BLOCKS the turn from ending
until it passes. This is the deterministic, external stop-gate the Claude Code
best-practices guide recommends — "a Stop hook runs your check as a script and
blocks the turn from ending until it passes" (code.claude.com/docs/en/best-practices)
— the real-exec answer to a Workflow's inability to exec a subprocess. It is the
authoritative deterministic gate for the autonomous-build-loop: the model does not
report the verdict here; the kernel does, via the process exit code.

Opt-in: inert unless the marker is present, so it never gates ordinary sessions.
Marker schema (``.abl-gate.json``, gitignored): {config?, diff_base?, diff_head?}.

A Stop hook must not fail hard — any error, missing marker, or un-runnable gate
allows the stop (exit 0). The only thing that blocks is a real non-zero exit from
the gate. Claude Code ends the turn after 8 consecutive blocks, bounding the loop.
"""
import json
import os
import subprocess
import sys

# The gate runs test suites + the zetetic checker; 15 min bounds a stuck gate.
# source: operational default (>= acceptance_gate.py per-gate ceiling x a few gates).
GATE_TIMEOUT_S = 900


def allow() -> None:
    """Let the turn end. A Stop hook signals 'no objection' by exiting 0 silently."""
    sys.exit(0)


def block(reason: str) -> None:
    """Block the stop so the model keeps working until the real gate passes."""
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


def repo_root() -> str:
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return os.getcwd()
    return out or os.getcwd()


def main() -> None:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except (ValueError, OSError):
        allow()
    if not isinstance(payload, dict):  # valid non-object JSON (e.g. []) -> fail open
        allow()
    if payload.get("stop_hook_active"):  # already in a forced continuation -> do not loop
        allow()

    root = repo_root()
    marker = os.path.join(root, ".abl-gate.json")
    if not os.path.isfile(marker):
        allow()  # not an autonomous build run -> do not gate normal turns
    try:
        cfg = json.load(open(marker))
    except (OSError, ValueError):
        allow()
    if not isinstance(cfg, dict):  # hand-edited non-object marker (e.g. []) -> fail open
        allow()

    gate = os.path.join(root, "tools", "acceptance-gate.sh")
    if not os.access(gate, os.X_OK):
        allow()
    args = [gate, "--config", os.path.join(root, cfg.get("config", "memory/acceptance-gates.loop.yaml"))]
    base, head = cfg.get("diff_base"), cfg.get("diff_head")
    if base and head:
        args += ["--diff-base", base, "--diff-head", head]

    try:
        proc = subprocess.run(args, cwd=root, capture_output=True, text=True, timeout=GATE_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired):
        allow()  # cannot run the gate -> do not hard-block the session

    if proc.returncode == 0:
        allow()  # accepted (real exit code 0) -> let the turn end

    unmet = []
    try:
        unmet = json.loads(proc.stdout).get("unmet", [])
    except ValueError:
        pass
    reason = ("Acceptance gate is not green (tools/acceptance-gate.sh exit %d). "
              "Keep working until it passes; show the gate output as evidence." % proc.returncode)
    if unmet:
        reason += " Unmet: " + "; ".join(unmet[:6])
    block(reason)


if __name__ == "__main__":
    main()
