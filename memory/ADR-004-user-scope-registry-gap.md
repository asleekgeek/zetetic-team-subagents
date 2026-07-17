# ADR-004: `_user` Registry Coverage Gap (issue #31)

## Status
Accepted — 2026-07-17

## Context

`memory-tool.sh` denied every write from `MEMORY_AGENT_ID=_user` to
`/memories/_user/*`:

```
Error: agent '_user' is not permitted to write scope '/memories/_user'
```

This is the exact path the checkpoint protocol prescribes for the top-level
interactive session:

- `hooks/session-start.sh` and `hooks/stop-context-guard.py` default
  `MEMORY_AGENT_ID` to `_user` whenever the caller is the main session, not a
  spawned team/genius agent.
- `token-budget.md`'s checkpoint procedure and `memory-writer.md`'s "primary
  path" both write to `/memories/<scope>/checkpoint.md`, where `<scope>` for
  the top-level session is `_user`.

ADR-001 (2026-04-24) closed the coverage gap for the 19 team agents and 97
genius agents but never added a scope entry for `_user` itself, because
`_user` is not a file under `agents/*.md` — the refactorer checklist that
drove ADR-001's 100%-coverage claim only walked that directory. `_user` is
instead the interactive human/session identity, already present in the
registry as a *token* (`curator_agents`, and as an owner/reader on `global`,
`lessons`, `quarantine`, `reviewer-prefs`, `cortex-viz`) — but never as the
owner of its own scope.

With `strict_unknown_scope: true` (ADR-001 §4), any write to an unregistered
scope is denied regardless of who the agent is — `memory/contract.md` §4.2
("no cross-scope writes ... from a scope's declared owner agents only") and
the existing `I2` e2e test in `scripts/test-memory-e2e.sh` deliberately
assert this for agent `_user` against an arbitrary unknown scope
(`/memories/zzz-unknown/`). That test's intent was never to forbid `_user`
from having ITS OWN scope — it was proving strict mode has no loophole. The
missing `_user` entry made `/memories/_user/` collateral damage of that
correct-in-general rule.

**Reconciling with the recorded 22:25/23:19 anomaly:** the reporting session
observed a `rethink` to `/memories/_user/checkpoint.md` as agent `_user`
succeed at 22:25 and the identical operation fail at 23:19, both on the same
`tools/memory-tool.sh`. Forensic comparison of every reachable copy of the
tool and its registries (live checkout, dev-symlink-mounted
`~/.claude/tools/`, plugin marketplace copy, plugin cache copy and its
`.orig-backup`) found them byte-identical, all shipping
`strict_unknown_scope: true` and no `_user` scope — i.e. the *current*,
reproducible state is unconditional denial (confirmed by this ADR's
companion e2e test `I12`, which fails before this fix). No artifact survives
to explain the earlier success (`~/.claude/memories/.registry.json`, the
per-user override checked before the repo seed, does not currently exist,
and `~/.claude/memories` — a separate, single-commit local git repo — has no
history for it either). The most likely explanation is a transient, since-
deleted per-user `.registry.json` (permissive or `_user`-inclusive) that
predates this fix; it cannot be reconstructed from available evidence, and
that specific data point is therefore left as "I don't know" rather than
asserted. It does not change the fix: `_user` needs a registered scope
regardless of how the earlier accidental success occurred.

## Decision

Add `_user` as its own registry scope, identical in shape to a team agent's
home scope (`engineer`, `architect`, etc.):

```json
"_user": {
  "owners": ["_user"],
  "readers": ["*"],
  "ttl_days": 30,
  "max_file_kb": 100
}
```

This is additive only. It does not touch `_user`'s existing curator/owner
grants on `global`, `lessons`, `quarantine`, `reviewer-prefs`, or
`cortex-viz` — those remain separate scopes with their own entries. It does
not weaken `strict_unknown_scope` or the `I2` guarantee: writes to any OTHER
unregistered scope by `_user` are still denied (verified by `I12`'s cross-
agent sub-assertion and the untouched `I2`).

## Alternatives considered

### (a) Route `_user`'s checkpoint through the existing `checkpoints` scope
**Rejected.** `checkpoints` (owners `*`, TTL 30d) is deliberately a *shared*
scratch scope for context-cap/compaction stubs written by any agent at any
threshold (`memory/contract.md` §8a) — filenames there are UUID-keyed, not
identity-keyed. Routing `_user`'s own durable checkpoint through it would
either collide with the shared-scope convention or require inventing a
`_user`-specific filename convention inside a scope whose whole point is
anonymity. `_user` needs the same durable, identity-keyed home every other
agent gets.

### (b) Special-case `_user` in `acl_check()` (treat `agent == "_user"` as
implicitly matching `defaults.owners`, bypassing `strict_unknown_scope`)
**Rejected.** `defaults.owners` already lists `["_user"]`, so this is what
callers likely assumed was happening — but the current code checks
`strict_unknown_scope` and denies BEFORE consulting defaults (see
`acl_check()`, `tools/memory-tool.sh`). Special-casing one agent id in the
ACL engine reintroduces exactly the "convention relying on agent
politeness" pattern ADR-001 was written to eliminate: an undocumented
carve-out that only auditors of the source (not the registry) would find.
An explicit registry entry keeps the ACL engine agent-agnostic and the grant
visible in the one file that is supposed to be authoritative
(`scope-coverage.md`).

## Consequences

### Positive
- The top-level session's own checkpoint protocol works exactly as
  documented in `token-budget.md` and `hooks/stop-context-guard.py`, with no
  code change to the ACL engine.
- `scope-coverage.md`'s coverage claim is now actually complete: it covers
  every entity that legitimately owns a home scope, not just entities with a
  file under `agents/`.

### Negative
- None identified. This is a pure registry addition; no existing grant is
  narrowed.

## Boy-scout note
While updating `scope-coverage.md`'s summary table for this change, its
"Distinct registry scopes" count (`28`) was found already stale — it never
included the `cortex-viz` external-plugin scope added earlier. Both the
summary table and the doc's `Verification` python snippet's expected output
are corrected in the same PR (now `30`, i.e. `+1` for `cortex-viz` that was
never counted `+1` for this ADR's `_user`).

## Reversibility
Type-2 (registry edit, no data migration) — removing the entry reverts to
the pre-fix denial with no state loss beyond files already written under
`/memories/_user/`.

## Sources
- `memory/ADR-001-scope-coverage.md` (the coverage model this ADR extends).
- `memory/contract.md` §4.2, §8a, §8b (own-scope write discipline,
  checkpoint scope semantics, block-vs-archival split).
- `scripts/test-memory-e2e.sh` `I2` (pre-existing, unmodified — proves
  strict mode still has no unknown-scope loophole) and `I12` (new,
  companion to this ADR — proves `_user`'s own scope works and cross-agent
  isolation into it still holds).
- GitHub issue: cdeust/zetetic-team-subagents#31.
