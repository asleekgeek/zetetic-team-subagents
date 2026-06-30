# ADR-003: Zetetic Spine Enforcement, claude.ai Science Priority, and Loop Test-Strength

## Status
Accepted — 2026-07-01

## Context

Three gaps were identified in how the plugin applies its own epistemic standard:

1. **The zetetic standard was stated but not run as a loop.** Every agent carries
   the four pillars (Logical / Critical / Rational / Essential) in `<zetetic-standard>`
   (team) or `<zetetic>` (genius), and the build-loop standard lived in
   `agents/orchestrator.md` + the skills' `zetetic_gate` frontmatter. But nothing
   turned the pillars into a *per-task loop* (recall → evidence/sources →
   adversarial-verify → remember) that every agent runs the same way. The
   `/zetetic:engineering-loop` was opt-in; an arbitrary agent spawn had no spine.

2. **No resource-priority convention, and `claude.ai Science` unreferenced.**
   `claude.ai Science` is a separate beta desktop app — a zetetic scientific-review
   engine (verify a claim, audit an ablation, bound a thesis). Agents had no
   convention to reach for it first when a task has a scientific-claim component,
   and no documented place to bind it once the beta exposes an MCP tool.

3. **Mutation testing existed but ran nowhere in the loops.** Test-strength
   (test-engineer Move 8; `tools/mutation_check.sh`; coding-standards.md §12) was
   agent guidance and a scoped tool, but the autonomous-build-loop's acceptance
   gates (`memory/acceptance-gates*.yaml`) contained no mutation/test-strength
   gate. A loop iteration could converge green with a suite that covers lines but
   kills no mutants. (Raised by the maintainer mid-implementation.)

### Hard constraints (from prior lessons; non-negotiable)
- On-demand reference docs are **not read spontaneously** → any safety-critical
  guidance must be **inline** in the agent (present at spawn).
- A Stop hook reaches the model only via `{"decision":"block","reason":…}` on
  stdout, exit 0; it must be loop-safe (`stop_hook_active`) and fail-open.
- Any `.md` under `agents/` is parsed as an agent → non-agent docs live under `rules/`.
- **Product-safety lesson (2026-06-10):** a broad check shipped to every session
  must be **report-only by default**; blocking is **opt-in**, never the default
  (encoded in `stop-acceptance-gate.py` and `mutation-sweep.sh`).
- Agents are token-optimized → inline additions must be **compact**.
- No fabrication (§8): `claude.ai Science` has no MCP tool name yet → do not invent one.

## Decision

### 1. Inline zetetic spine in every agent (single generated block)
A compact `<zetetic-spine>` block (recall → evidence/sources → adversarial-verify →
remember, calibrated by stakes, "failed gate ⇒ STOP", "say I don't know") is
injected into all 117 anchor-bearing agents by `scripts/generate-spine.py`,
immediately after the existing `</zetetic-standard>` or `</zetetic>` tag (detected
by tag, not directory — feynman is a genius using `<zetetic>`). The generator is
idempotent (delimited by HTML comments; 2nd run is a no-op) and has a `--check`
mode for CI. The block carries the **resource-priority line inline** (rather than a
second `<resources>` section, as the plan first sketched) — one delimited block per
file minimizes churn across 117 agents and ties the resource priority to the spine's
own evidence beat. Full elaboration: `rules/agent-reference/zetetic-spine.md`.

**Calibration.** Research + epistemic agents (research-scientist, data-scientist,
reviewer-academic, paper-writer, professor; popper, cochrane, feynman, peirce,
fisher, semmelweis) get first-recourse wording for `claude.ai Science`; all others
get awareness wording. 11 strong + 106 standard.

**Deliberate exclusion.** `memory-writer` (a 16K-budget scribe that makes no claims,
designs no tests, writes no code) is excluded — the full spine would be process
theater (Rational/Essential pillars); it already embodies the discipline
domain-specifically. The generator's no-anchor warning therefore flags only genuine
oversights.

### 2. `claude.ai Science` as a documented first-recourse resource + binding slot
New `rules/agent-reference/research-resources.md` fixes the priority order **by
usage**: claim verification / ablation audit / thesis-bounding → `claude.ai Science`
(Tier 0), then the primary source, then WebSearch; with a §8 source-discipline
recap. It documents the **binding slot** (where to add the real `mcp__…` tool name
in `.mcp.json` / per-agent `tools:` / the spine generator) once the beta exposes it,
with an explicit "do not invent the name" rule. `post-research-provenance.sh` is
extended to label a science-review call `verified (claude.ai Science)` (vs
`consulted`) by tool_name pattern — forward-compatible, harmless until the matcher
routes the real tool.

### 3. Turn-level spine gate — WARN default, BLOCK opt-in
`hooks/stop-zetetic-spine.py` (wired into `hooks/hooks.json` + `.claude-plugin/plugin.json`)
is report-only (WARN, one-time per session) by default: when a turn changed state
(Edit/Write) with no recall/memory/web-evidence activity in the transcript tail, it
surfaces a non-blocking reminder. It **blocks** only under an explicit opt-in marker
(`.zetetic-spine.json` or `ZETETIC_SPINE_BLOCK=on`), for autonomous runs that want
hard gating. This mirrors `stop-acceptance-gate.py` and honors the product-safety
lesson rather than the plan's looser "fail-closed everywhere" phrasing.

### 4. Test-strength gate in the loop — `tools/mutation-gate.sh`
A new wrapper around `tools/mutation_check.sh`, wired as a mandatory base gate in
both `memory/acceptance-gates.yaml` (`--staged`) and `acceptance-gates.loop.yaml`
(`{files}`), makes the autonomous loop run mutation testing on the changed code.
Its contract is **proportional and sound**:
- no mutation-applicable changed source → PASS;
- applicable source + runner ready → run per language; a **surviving mutant → BLOCK**;
- applicable source + no runner/config → **degrade loudly** (warn, pass), verbatim
  per test-engineer Move 8 step 2 — never silently block a tool-less environment,
  never fake a result not executed. The authoritative external check remains the
  human/CI re-gate (autonomous-build-loop INV-2).

The spine's adversarial-verify beat now names this explicitly (inline + elaboration).
The wrapper is itself gated by `tools/tests/mutation-gate/run-tests.sh` (gate-the-gate).

**Why a wrapper, not a raw `mutation_check.sh` gate, and why graceful rather than
hard-blocking on a missing runner:** the existing architecture deliberately keeps
mutation as an agent Move + scoped tool because selecting the right test scope needs
judgment, and §12.5 forbids freezing environments on a heavy/setup-dependent check.
The wrapper preserves both: real survivors block; everything else degrades visibly.

## Consequences

**Positive**
- The zetetic loop is now present at every spawn, not opt-in — calibrated to stakes.
- Scientific verification has a first-recourse resource and a ready binding slot.
- The autonomous loop can no longer converge green on a line-covering but
  mutant-surviving suite where a runner exists; where none exists, the gap is loud.
- One generated block + one generator = single source; `--check` keeps it honest.

**Negative / trade-offs**
- 117 agent files changed (delimited, idempotent, regenerable — low risk).
- The mutation gate degrades (does not block) when no runner is configured — in this
  repo (`mutmut` absent) it currently warns rather than enforces; enforcement is real
  only where a runner is installed. This is the deliberate §12.5 / Move 8 contract,
  not a silent disable: the warning is loud and the human/CI re-gate is authoritative.
- The default spine Stop gate is advisory; hard enforcement is opt-in per run.

## Provenance
- Zetetic standard vocabulary: `agents/orchestrator.md` `<zetetic-standard>`; skills' `zetetic_gate`.
- Product-safety (report-only default): `hooks/stop-acceptance-gate.py`, `tools/mutation-sweep.sh` (2026-06-10).
- Mutation policy: coding-standards.md §12; test-engineer Move 8; DeMillo–Lipton–Sayward (1978); Jia & Harman (2011).
- Self-verification: Workflow/judge-as-oracle caveat — arXiv:2310.01798 (the loop's external-gate rationale).
