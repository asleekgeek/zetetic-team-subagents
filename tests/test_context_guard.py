"""Unit tests for hooks/stop-context-guard.py's payload and threshold helpers.

These two functions were extracted from `main()` so that the locals they feed
are bound on every path (CodeQL py/uninitialized-local-variable, alerts #28/#29
— the annotation-based fix did not satisfy the query because it is
intraprocedural and does not read `NoReturn`). Extracting them for an analyser's
benefit only pays off if the extracted contract is actually pinned, so it is
pinned here: every branch of both helpers, including the ones that exist to keep
the hook fail-open.

The module is loaded by path rather than imported: `stop-context-guard.py` has
hyphens in its name and hooks/ is not a package, so there is no dotted path for
it. That also keeps the hook's own `sys.exit()`-based flow out of these tests —
the helpers are pure and return.
"""
from __future__ import annotations

import importlib.util
import io
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
HOOK_PATH = REPO_ROOT / "hooks" / "stop-context-guard.py"


def _load_hook():
    spec = importlib.util.spec_from_file_location("stop_context_guard", HOOK_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = _load_hook()


# ── _read_payload ────────────────────────────────────────────────────────────

def test_read_payload_returns_the_parsed_object(monkeypatch):
    payload = {"session_id": "s1", "cwd": "/tmp/x"}
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(payload)))
    assert guard._read_payload() == payload


@pytest.mark.parametrize(
    "raw",
    [
        "",                 # empty stdin — hook invoked with no payload
        "not json at all",  # plain text
        '{"unclosed": ',    # truncated object
        "\x00\x01",         # binary noise
    ],
)
def test_read_payload_returns_none_on_unparseable_stdin(monkeypatch, raw):
    """The fail-open contract: a broken payload must not raise out of the hook."""
    monkeypatch.setattr(sys, "stdin", io.StringIO(raw))
    assert guard._read_payload() is None


@pytest.mark.parametrize("raw", ["42", '"a string"', "[1, 2]", "null", "true"])
def test_read_payload_passes_through_valid_non_objects(monkeypatch, raw):
    """Valid JSON that is not an object parses fine; main() rejects it by shape.

    Pinned separately from the None case because the two reach the same exit via
    DIFFERENT routes, and collapsing them in a test would hide a regression that
    made one of them raise instead.
    """
    monkeypatch.setattr(sys, "stdin", io.StringIO(raw))
    result = guard._read_payload()
    assert not isinstance(result, dict)


@pytest.mark.parametrize("raw", ["{}", "", "garbage", "[]", "null", "\x00"])
def test_read_payload_never_raises(monkeypatch, raw):
    """The property the extraction exists for: the call always RETURNS.

    `main()` reads `data` unconditionally on the line after the call, so the
    only way that read can be unbound is if this function propagates instead of
    returning. Totality is the contract; the value itself is checked above.
    """
    monkeypatch.setattr(sys, "stdin", io.StringIO(raw))
    guard._read_payload()  # must not raise


# ── _level_for ───────────────────────────────────────────────────────────────

WARN, HARD = 100, 200


@pytest.mark.parametrize(
    "ctx,expected",
    [
        (0, None),          # far below
        (99, None),         # just below warn
        (100, "warn"),      # exactly warn — inclusive
        (150, "warn"),      # between
        (199, "warn"),      # just below hard
        (200, "hard"),      # exactly hard — inclusive
        (10_000, "hard"),   # far above
    ],
)
def test_level_for_boundaries(ctx, expected):
    assert guard._level_for(ctx, WARN, HARD) is expected


def test_level_for_returns_on_every_branch():
    """Total by construction — the reason `level` is bound in main()."""
    for ctx in range(0, 260, 7):
        assert guard._level_for(ctx, WARN, HARD) in {None, "warn", "hard"}


def test_level_for_prefers_hard_when_thresholds_coincide():
    """Degenerate config (warn == hard) must resolve to the stricter band.

    `_thresholds` rejects warn >= hard and falls back to defaults, so this is
    not reachable through the hook today — but the helper is public to the
    module and the ordering is the part a future edit could silently invert.
    """
    assert guard._level_for(150, 150, 150) == "hard"
