# Changelog

All notable changes to this project will be documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.18.0] — letta-code follow-up: lean genius corpus, compact routing, reflective checkpoints, memory contract hardening

### Changed

- **R1 completed for the genius corpus: all 97 genius agents split into lean
  core + on-demand reference stubs** (same two-tier move 2.17.0 applied to the
  19 team agents). Doc-covered protocol sections deleted; memory/token-budget/
  worktree replaced by parameterized stubs keeping every safety-critical
  invariant inline; uniform reference-docs index appended. 5,169,780 →
  3,248,016 chars (37.2%, ~4.8K tokens saved per spawn per agent). Reasoning
  sections byte-identical before/after, asserted by the rollout script.
- **R2: routing never reads full files.** New generated
  `rules/agent-routing-table.md` (~25KB, name + shape keywords + description
  for all 116 agents, from frontmatter via
  `scripts/generate-routing-table.py`) replaces full Reads of the 132KB
  INDEX.md in genius:route, genius:index and the orchestrator (~30K tokens
  saved per routing decision). pre-commit warns when the table is stale.
- **R3: checkpoint stubs follow the letta summary schema** — goals / file
  references (paths + line ranges) / errors and fixes / current state / next
  steps, ≤500 words, tool outputs clipped to 2K chars, frontmatter
  description retrieval cue. Resume contract: checkpoint + ONE targeted
  recall, never re-reading what the checkpoint summarizes. All 116 agent
  token-budget stubs and the shared token-budget.md doc teach the schema.
- **R4: reflection at WARN, not at HARD.** stop-context-guard.py's WARN
  firing is now a one-time blocking reflection (like letta's compaction
  event): the model spawns the new budgeted **memory-writer** agent (haiku,
  ≤16K context) to persist the semantic checkpoint + cortex:remember entries
  while headroom remains, then resumes the task — the HARD block becomes a
  formality.

### Added

- **R5: mandatory `description:` frontmatter on memory .md files**, enforced
  at the memory-tool.sh chokepoint on create/rethink (instructive error,
  `MEMORY_NO_DESC_CHECK=1` test escape hatch). Contract §4.8.
- **R6: conflict-aware memory verbs** — `rethink <path> <text>
  [expected_sha]` (atomic whole-file rewrite, letta memory_rethink) and
  `sha <path>` (CAS token); `str_replace` gains optional compare-and-swap.
  Contract §3.6b/§3.6c/§4.7; exposed via the memory_extensions MCP tool.
- `agents/memory-writer.md` — single-purpose budgeted reflection scribe.

## [2.17.0] — Lean team agents: core + on-demand reference docs

### Changed

- **All 19 team agent definitions split into a lean core plus on-demand
  reference docs.** Shared protocol detail (token budget, memory protocol
  and architecture, worktree protocol, effort calibration, codebase
  intelligence, dynamic workflows, mid-task system messages) moved to 8
  docs under `rules/agent-reference/`, referenced from a uniform index
  table in every agent. Definitions shrink 987,888 → 625,267 chars
  (~36.7%, ~5.0K tokens saved per spawn per agent). Inline stubs remain
  self-sufficient for safety-critical invariants (checkpoint thresholds,
  memory scoping, worktree commit rules); reference docs are elaboration
  and recovery material, validated via headless fresh-session runs.
- Agent frontmatter parameterized (`agent_topic`, `memory_scope`,
  `model`); Haiku agents carry 170K/~120K budgets plus an
  escalate-to-orchestrator line, Opus agents 200K/~180K. Fixed
  latex-engineer/professor `MEMORY_AGENT_ID=haiku` bug (now agent name)
  and the orchestrator's dangling `<dynamic-workflows>` prose reference.

## [2.16.0] — Per-model context thresholds via shared config

### Changed

- **stop-context-guard.py re-vendored from
  [session-optimizer](https://github.com/cdeust/session-optimizer) v1.1.0.**
  Thresholds are now per-model and loaded from
  `~/.claude/ctxguard-thresholds.json` (embedded fallback when the config
  is absent or malformed; first substring match on the lowercased model id
  wins): Fable 5 / Mythos warn 120K hard 160K (2x Opus rates — carrying
  rent and the 5-min cache-expiry resume penalty bite twice as hard),
  Haiku 4.5 warn 120K hard 170K (200K IS the window; leave headroom for
  the checkpoint turn), Opus/Sonnet warn 180K hard 200K (cost discipline;
  window is 1M). The hard-cap block message now reports the per-model
  budget instead of a fixed 200K.
- **`<token-budget>` model-limits table updated in all 117 agent docs.**
  Adds the Claude Fable 5 row (160K hard cap, ~120K checkpoint), corrects
  Haiku's cap to 170K, and points to `ctxguard-thresholds.json` as the
  authoritative source shared with the statusline and the Stop guard.

### Added

- **`hooks/ctxguard-thresholds.json`** — vendored copy of the shared
  threshold config. `session-start.sh` seeds it to
  `~/.claude/ctxguard-thresholds.json` when absent (idempotent — never
  overwrites user edits, so tuned thresholds survive plugin updates).

## [2.15.0] — Complete the plugin hook manifest

### Fixed

- **Missing hooks in the plugin manifest.** `.claude-plugin/plugin.json`
  had drifted from `hooks/hooks.json`: the inline `hooks` block omitted
  three hooks that the canonical wiring defines, so they never registered
  when the plugin loaded — `pre-tool-secret-shield.py` (PreToolUse),
  `stop-context-guard.py` (Stop, the context-budget guard from
  [session-optimizer](https://github.com/cdeust/session-optimizer)), and
  `session-end-memory-drain.sh` (Stop). The manifest now mirrors
  `hooks/hooks.json` exactly (17 hook commands). The Stop block fires all
  three lifecycle hooks; PreToolUse re-includes the secret shield.

### Changed

- Marketplace entry hook count corrected (16 → 17).

## [2.14.0] — Public-readiness baseline

### Added

- Public-readiness baseline: CONTRIBUTING.md, CODE_OF_CONDUCT.md,
  SECURITY.md.
- GitHub issue templates (bug / feature / audit-finding) and PR template
  with audit-cycle checklist.
- `prd-spec-generator` row in the companion-projects table.

### Changed

- LICENSE copyright corrected to Clément Deust (sole independent author);
  ecosystem-context preamble + explicit non-affiliation statement added.
- LinkedIn post first-comment options refined for algorithm-aware reach.

## [2.13.1] — Tier-1 visibility + memory MCP + PII scanner

### Added

- **Memory MCP.** Local replica of Anthropic's managed-agent
  `memory_20250818` tool with scope-based ACL, queue isolation, and
  full MCP wire compatibility. 241 tests passing across functional, ACL,
  concurrency, stale-lock, MCP, and PII suites.
- **PII / secret scrubbing on memory write path** (contract §7.2).
- **`pre-tool-secret-shield` hook** — blocks any agent from reading
  `.env`, `.aws/credentials`, `*.pem`, `*.key`, or shell-history files.
- **PII scanner daemon.** Persistent process eliminates Python cold-start;
  median scan time reduced 34→8 ms.
- **Memory contract on every agent.** `memory_scope` frontmatter +
  `memory` body block added to all 19 team agents and all 97 genius
  agents (so each agent declares what it persists and where).
- README rewrite (Tier 1 visibility), 6 supporting docs, full CI matrix,
  Codespaces config (subsequently removed per cross-check feedback).

### Changed

- CI concurrency suite made Linux-portable (was macOS-specific).

### Documentation

- LinkedIn post series introducing zetetic (rewritten in plain prose; no
  em-dashes).

---

For older releases (v2.13.0 and earlier), see git history. The project
predates this CHANGELOG; pre-2.13.1 versioning was driven by tag-only
release notes on GitHub.
