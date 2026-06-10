# Changelog

All notable changes to this project will be documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
