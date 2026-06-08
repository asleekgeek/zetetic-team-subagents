#!/usr/bin/env python3
"""
Patch 3: Correct model specs and tiering based on official Anthropic docs.

Changes:
1. Fix model tiering:
   - opus  → genius/*, orchestrator, architect, security-auditor
             (long-horizon autonomy, deep complex coding, cybersecurity)
   - sonnet → engineer, test-engineer, refactorer, frontend-engineer,
              devops-engineer, dba, mlops, code-reviewer, data-scientist,
              experiment-runner, paper-writer, reviewer-academic, ux-designer
              (agile coding, agent planning & execution, production-ready apps)
   - haiku  → latex-engineer, professor
              (latency-sensitive, executing pre-planned tasks)
   Note: haiku's 200K context = the token budget is a hard limit, not advisory.

2. Replace <effort-calibration> with corrected version including:
   - Official model specs (context window, cost, TPS)
   - Correct use-case mapping per Anthropic docs
   - Haiku 200K = hard constraint callout

3. Fix <mid-task-system-messages>: clarify the API mechanism —
   "system" as a ROLE in conversation history (not a top-level param change),
   cache stays intact because top-level system param is unchanged.
"""
import os
import re

AGENTS_DIR = os.path.join(os.path.dirname(__file__), "..", "agents")

# Corrected tiering
OPUS_TEAM = {"orchestrator", "architect", "security-auditor"}
SONNET_TEAM = {
    "engineer", "test-engineer", "refactorer", "frontend-engineer",
    "devops-engineer", "dba", "mlops", "code-reviewer", "data-scientist",
    "experiment-runner", "paper-writer", "reviewer-academic", "ux-designer",
}
HAIKU_TEAM = {"latex-engineer", "professor"}
# All genius → opus (unchanged)

NEW_EFFORT_SECTION = """\
<effort-calibration>
## Model Selection & Effort Calibration

### Official model specs (Anthropic, June 2026)

| Model | Context | Output | Cost (in/out MTok) | Latency | Best for |
|---|---|---|---|---|---|
| Claude Opus 4.8 | 1M | 128K | $5 / $25 | ~77 TPS | Hardest work, peak intelligence, sustained autonomy |
| Claude Sonnet 4.6 | 1M | — | $3 / $15 | ~72 TPS | Building & iterating — coding workflows, agent prototyping |
| Claude Haiku 4.5 | **200K** | — | $1 / $5 | ~109 TPS | Executing pre-planned tasks, latency-sensitive, cost-sensitive |

**Haiku context limit is a hard technical constraint**: Haiku 4.5 has a 200K context window — identical to the session token budget. For haiku agents, the 200K checkpoint protocol is not advisory; it is the model's physical limit.

### Which model when (per Anthropic recommendation)

**Use Opus 4.8 when:**
- Long-horizon agent tasks requiring sustained autonomy with minimal oversight
- Deep, complex coding across large codebases
- Cybersecurity work requiring sustained focus across long traces
- Precision enterprise workflows (finance, legal, formal verification)
- Multimodal reasoning

**Use Sonnet 4.6 when:**
- Agent planning & execution (building workflows, not just following them)
- Agile coding — iterating on a feature, not just executing a spec
- Agent prototyping and development cycles
- Production-ready applications
- Efficient research

**Use Haiku 4.5 when:**
- The task has been fully planned by a more capable model and execution is mechanical
- Latency-sensitive path (user-facing, real-time)
- Content generation at scale (ad copy, templating, formatting)
- Efficient research on bounded, well-specified questions

### Effort levels (Opus 4.8 only — controls extended thinking depth)

| Task | Effort | Rationale |
|---|---|---|
| Reading files, I/O, listing | low | No reasoning required |
| Implementing a fully-specified plan | low | Plan already did the reasoning |
| Bug fix with clear root cause | low–medium | Light application of judgment |
| Architecture decision, PRD | medium | Structured reasoning over bounded search space |
| Multi-disciplinary analysis, research synthesis | medium | Judgment required but not open-ended |
| Formal verification, concurrency proof, security audit | high | Correctness is load-bearing; wrong answer is worse than slow |
| Genuinely stuck / surprising result / blocker | high | Use extended thinking to break impasse |

**Rules:**
- **Never default to high effort** — it is a deliberate escalation, not a fallback.
- **Prefer fast mode** (`/fast`) for Opus 4.8 tasks where peak correctness is not required — 2.5× output speed at same intelligence ($10/$50 MTok fast mode vs $5/$25 standard).
- **Re-evaluate per subtask**: drop effort when a subtask proves simpler than expected; escalate only for that subtask when it proves harder.
- **Token budget interaction**: high effort burns more tokens per turn. Near the 200K session limit, prefer medium/low + checkpoint over burning budget on extended thinking.
- **Cost-aware orchestration**: an opus high-effort turn costs ~50× a haiku turn. Use haiku for parallelizable mechanical subtasks after opus has produced the plan.
</effort-calibration>
"""

# Corrected mid-task system messages section
OLD_MID_TASK_OPEN = "<mid-task-system-messages>"
OLD_MID_TASK_CLOSE = "</mid-task-system-messages>"

NEW_MID_TASK_SECTION = """\
<mid-task-system-messages>
## Mid-Task System Messages (Opus 4.8 — Research Preview)

**Technical mechanism:** The Messages API now supports `"system"` as a **role inside the conversation history** (not a change to the top-level `system` parameter). Agents can update Claude's instructions mid-task without editing the top-level system prompt — which means the prompt cache stays intact and earlier turns keep hitting cache.

**Why this matters:**
- Cache stays intact: the top-level `system` param never changes, so cached system prompt, tool definitions, and earlier turns all keep hitting the cache. No cache-busting cost.
- Operator channel: `"system"` role messages inside the conversation are recognized by Claude as operator-authored instructions — more reliable and trustworthy than embedding system instructions inside user turns.

### You receive; you do not initiate

Mid-task system messages are injected by the **harness/orchestrator**. The agent receives and obeys them; it cannot send one to itself. This is a developer API feature.

### How to handle a received mid-task system message
1. Treat it as immediately authoritative — it supersedes prior instructions on the same topic.
2. Continue from the current position without re-deriving context (cache is intact).
3. If the update changes task scope or resource budget, record the delta in memory:
   ```bash
   MEMORY_AGENT_ID=<your-id> tools/memory-tool.sh create /memories/<scope>/scope-history.md \
     "<ISO-date>: received mid-task system message — <what changed>"
   ```
4. If the update contradicts already-completed work, surface the conflict: state what was done under the old instructions and whether outputs need revision.

### How to signal the harness that you NEED a mid-task update
If you discover mid-task that a constraint makes the original task impossible, or a new permission or budget is required, **pause and emit a structured signal** — do not improvise:
```
SCOPE_UPDATE_REQUEST: {
  "reason": "<one sentence>",
  "current_task": "<what you were doing>",
  "blocker": "<what changed or was discovered>",
  "requested_change": "<what you need from the harness>"
}
```
The orchestrator will respond with a mid-task system message (granting or denying).

### What NOT to do
- Do not embed a scope update in a user turn — it bypasses the operator channel and may break caching.
- Do not silently widen your own permissions or budget.
- Do not ignore a received system message — apply it immediately.
</mid-task-system-messages>
"""


def get_correct_model(name: str, is_genius: bool) -> str:
    if is_genius:
        return "opus"
    if name in OPUS_TEAM:
        return "opus"
    if name in HAIKU_TEAM:
        return "haiku"
    return "sonnet"  # sonnet is now the default for team agents


def patch_file(path: str, name: str, is_genius: bool) -> bool:
    with open(path) as f:
        content = f.read()

    original = content

    # 1. Update model in frontmatter
    new_model = get_correct_model(name, is_genius)
    content = re.sub(r"^model: \w+", f"model: {new_model}", content, flags=re.MULTILINE)

    # 2. Replace <effort-calibration>...</effort-calibration>
    effort_pattern = re.compile(
        re.escape("<effort-calibration>") + r".*?" + re.escape("</effort-calibration>"),
        re.DOTALL,
    )
    if effort_pattern.search(content):
        content = effort_pattern.sub(NEW_EFFORT_SECTION.rstrip(), content, count=1)
    elif "<effort-calibration>" not in content:
        content = content.rstrip() + "\n\n" + NEW_EFFORT_SECTION.rstrip() + "\n"

    # 3. Replace <mid-task-system-messages>...</mid-task-system-messages>
    mid_pattern = re.compile(
        re.escape(OLD_MID_TASK_OPEN) + r".*?" + re.escape(OLD_MID_TASK_CLOSE),
        re.DOTALL,
    )
    if mid_pattern.search(content):
        content = mid_pattern.sub(NEW_MID_TASK_SECTION.rstrip(), content, count=1)

    # 4. Update fast mode pricing in token-budget (correct from $10/$50 to $10/$50 fast / $5/$25 standard)
    content = content.replace(
        "2.5× speed at the same intelligence level.",
        "2.5× speed ($10/$50 MTok fast vs $5/$25 standard).",
    )

    if content == original:
        return False

    with open(path, "w") as f:
        f.write(content)
    return True


def main():
    changed = skipped = 0

    for fname in sorted(os.listdir(AGENTS_DIR)):
        if not fname.endswith(".md"):
            continue
        name = fname[:-3]
        path = os.path.join(AGENTS_DIR, fname)
        if patch_file(path, name, is_genius=False):
            changed += 1
            print(f"  patched: agents/{fname}")
        else:
            skipped += 1

    genius_dir = os.path.join(AGENTS_DIR, "genius")
    for fname in sorted(os.listdir(genius_dir)):
        if not fname.endswith(".md"):
            continue
        path = os.path.join(genius_dir, fname)
        if patch_file(path, fname[:-3], is_genius=True):
            changed += 1
            print(f"  patched: agents/genius/{fname}")
        else:
            skipped += 1

    print(f"\nDone: {changed} patched, {skipped} skipped")


if __name__ == "__main__":
    main()
