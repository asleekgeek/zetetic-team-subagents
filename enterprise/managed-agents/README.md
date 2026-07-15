# CMA facilitator agents — enterprise pilot engagements

Phase A of [issue #26](https://github.com/cdeust/zetetic-team-subagents/issues/26)
("enterprise: CMA facilitator agents"). Version-controlled manifests for the
4 Claude Managed Agents (CMA) that facilitate the meta-work of a Claude Code
enterprise pilot engagement, plus the shared environment they attach to.

## Architecture — two planes, no overlap

The engagement runs on two distinct planes, decided in the issue #26
"Architecture finale" comment (2026-07-15):

1. **The field (local, at the client site)**: the architect brings the
   zetetic-team-subagents roster and the Cortex/zetetic ecosystem, installed
   locally at the client under the Claude Enterprise edition. This plane does
   the actual engineering work. Nothing about it changes here — no agent is
   ported to CMA.
2. **The engagement's meta-work (CMA, server-side)**: 4 small, specialized,
   versioned facilitator agents that handle the steps the field plane
   should not carry — reporting, analysis, fleet health, and security audit.

| Facilitator | Handles | CMA capability exploited |
|---|---|---|
| `reporting` | Scorecards and readouts from exported OTel/Admin data | scheduled deployment (weekly cron); outcome rubric on the readout; `.xlsx`/`.docx` deliverables via skills |
| `analysis` | Baseline/adoption diagnosis: cohorts, chasm, common- vs special-cause variation | engagement memory store (baseline, decision history); Console-traced sessions |
| `agent-management` | Deployed-fleet health: plugin/marketplace version drift, config drift vs managed templates, inventory | versioned agent + `github_repository` mount of the client's config repo; webhooks |
| `security-data-audit` | Security questionnaire, MCP governance, data-surface/retention audit | outcome-rubric-gradable checklist; versioned memory store + redact |

Why this split: the local plane keeps what no CMA agent can offer (full
roster, worktrees, hooks, Cortex); CMA offers what the local plane cannot
(autonomous cron, org-side versioned objects, sessions the client can see in
their own Console, gradable outcomes, a durable and redactable per-engagement
memory). The facilitators are also billable pilot deliverables — the client
sees the reporting/audit sessions in their Console — not an internal cost.

## Interim memory mechanism (Phase A) — native CMA memory stores

Per the issue's priority-ordering comment (2026-07-15): facilitator memory
uses **native CMA memory stores** (FUSE-mounted, versioned, redactable) for
this phase. The centralized cross-engagement memory (Cortex#144) and the
`cortex-relay` MCP bridge (Cortex#151) come later, in that dependency order.
None of the 4 manifests declare `mcp_servers` — this is deliberate, not an
oversight. When the relay ships, migrating a facilitator to it is an
`ant beta:agents update` adding an `mcp_servers` entry and a vault, not a
manifest rewrite.

## Deployment flow

### Control-plane CI — creating and versioning an agent

```bash
# First deploy of a facilitator (creates version 1)
ant beta:agents create < enterprise/managed-agents/reporting.agent.yaml

# Subsequent changes to the manifest — bump the version explicitly
ant beta:agents update reporting --version 2 < enterprise/managed-agents/reporting.agent.yaml
```

Repeat per facilitator (`reporting`, `analysis`, `agent-management`,
`security-data-audit`). Each manifest is the single source of truth for its
agent's `system` prompt, model, tools, and skills — do not hand-edit an
agent through the console once it is under version control here; edit the
YAML, bump the version, and re-run `update`.

CI wiring (recommended, not yet implemented in this repo): a workflow that
runs `ant beta:agents update <name> --version <n>` on merge to `main` for
any changed `*.agent.yaml`, gated on the YAML-parse + schema checks below
already passing.

### Attaching the environment

```bash
ant beta:environments create < enterprise/managed-agents/pilot.environment.yaml
```

See the **honest limit** note inside `pilot.environment.yaml` — every field
in that file beyond `name`/`description` is a best-effort hypothesis about
the real `CreateEnvironment` schema, not a verified one. Phase B's first job
is running this against a real `ant beta:agents create` / environments call
on a test workspace and correcting the manifest from what the API actually
accepts.

### Attaching memory stores per engagement

At the start of a new client engagement, attach a fresh memory-store
instance to the environment for that engagement (native CMA memory store,
per the interim mechanism above) before the first facilitator session runs.
The exact attach command is part of the Phase B validation — this repo does
not yet script it, because the environment schema itself is unverified.

### Scheduled deployment (reporting)

`reporting` is the one facilitator with a cron requirement — see
`scheduled_deployments` in `pilot.environment.yaml`. The weekly cadence
exists so a scorecard/readout draft is already sitting in
`/mnt/session/outputs/` before the consultant or sponsor asks for it, per
the reporting agent's system prompt. The cron schedule and format in the
manifest are marked ASSUMED — validate against the real scheduling API in
Phase B.

### Vaults for secrets

`agent-management` and `security-data-audit` read client data (a mounted
config repository, an environment/config snapshot) that requires
credentials. Those credentials belong in a vault attached to the
environment, substituted into the session at start — never embedded in an
agent's `system` prompt, never committed to this repository. See the
`vaults` block in `pilot.environment.yaml` for the (also-ASSUMED) shape.

## PoC criteria — Phase B (not yet run)

Phase B validates the 3 facilitators whose capabilities are most novel
against a real CMA workspace:

(a) **reporting** — a scheduled deployment fires on cron against a test
    OTel data export, produces a `.docx` readout, and the readout satisfies
    a defined outcome rubric.
(b) **agent-management** — a deliberate version drift is introduced into a
    test config repository; the facilitator detects it and reports it with
    the field/expected/actual evidence format its system prompt requires.
(c) **security-data-audit** — the governance checklist runs against a test
    environment with a known-good and a known-bad `managed-settings.json`
    (once with `allowManagedMcpServersOnly: true`, once without) and
    correctly flags the difference.

None of (a)-(c) has been run. This phase-A delivery is manifests and a
system-prompt design grounded in the Anthropic activation-guide reference
material (measurement, pilot-qualification, security-questionnaire,
managed-settings, MCP-governance, and plugins-handoff lessons) — it is not
a claim that the manifests work against the live Managed Agents API. That
claim is exactly what Phase B is for.

## Phase C (later)

Integration into the pilot offer: which facilitators ship by default in a
standard pilot, and how they are priced.
