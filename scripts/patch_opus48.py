#!/usr/bin/env python3
"""
Patch 2: Opus 4.8 accuracy fixes for all 117 agent files.

Changes:
1. Replace <scope-update> with corrected <mid-task-system-messages> section
   (it's a harness feature the model RECEIVES, not initiates)
2. Add <effort-calibration> section — default low/medium, high only when required
3. Patch <token-budget> to mention fast mode (/fast)
"""
import os
import re

AGENTS_DIR = os.path.join(os.path.dirname(__file__), "..", "agents")

# The old section to replace (match opening tag to closing tag)
OLD_SCOPE_TAG_OPEN = "<scope-update>"
OLD_SCOPE_TAG_CLOSE = "</scope-update>"

NEW_MID_TASK_SECTION = """\
<mid-task-system-messages>
## Mid-Task System Messages (Opus 4.8 — Research Preview)

**What this is:** The orchestrator/harness can inject a system-level instruction update mid-conversation — without breaking the prompt cache and without routing it through a user turn. This is a *harness* capability. You receive it; you do not initiate it.

**What it carries:** Token budget updates, permission changes, environment context changes, scope narrowing or expansion, priority shifts. It arrives as a system message between assistant turns.

### How you respond to a mid-task system message
1. **Acknowledge the update** — treat the new system message as immediately authoritative. It supersedes any prior instruction on the same topic.
2. **Do not re-derive context from scratch** — the prompt cache is intact; continue from where you were, applying the updated constraint.
3. **Record the delta in memory** if the update changes your task scope or resource budget:
   ```bash
   MEMORY_AGENT_ID=<your-id> tools/memory-tool.sh create /memories/<scope>/scope-history.md \
     "<ISO-date>: received mid-task system message — <what changed>"
   ```
4. **If the update contradicts work already done**, surface the conflict immediately: state what was done under the old instructions, what the new instruction says, and which outputs (if any) need to be revised.

### How to signal the harness that you NEED a scope update
If mid-task you discover that:
- A constraint makes the original task impossible or significantly wrong
- A sub-agent result eliminates an entire branch of planned work
- A new permission or token budget is required to proceed

…do NOT improvise or widen your own scope. Instead, pause and emit a structured signal:
```
SCOPE_UPDATE_REQUEST: {
  "reason": "<one sentence>",
  "current_task": "<what you were doing>",
  "blocker": "<what changed or was discovered>",
  "requested_change": "<what you need from the harness>"
}
```
The orchestrator will respond with a mid-task system message granting or denying the request.

### What NOT to do
- Do not fake a scope update by inserting a user-turn clarification — it burns context and breaks cache.
- Do not silently widen your own permissions or budget mid-task.
- Do not ignore a received system message — apply it immediately and record the delta.
</mid-task-system-messages>
"""

EFFORT_SECTION = """\
<effort-calibration>
## Effort Calibration (Opus 4.8)

Opus 4.8 exposes an explicit **effort** control. Lower effort = faster responses + slower rate-limit burn. Higher effort = extended thinking for harder problems. **Default to the lowest effort that produces a correct result.**

### Decision table

| Task type | Effort | Rationale |
|---|---|---|
| Reading files, grepping, listing | low | Pure I/O — no reasoning required |
| Routine implementation following a detailed plan | low | Plan already did the reasoning |
| Bug fix with a clear root cause | low–medium | Apply the fix; reasoning is light |
| Code review, analysis report | medium | Judgment required but bounded |
| Architecture decision, PRD, design | medium | Structured reasoning, not open-ended search |
| Formal verification, concurrency proof, security audit | high | Correctness is load-bearing; wrong answer is worse than slow |
| Stuck / blocked / surprising result | high | Use extended thinking to break the impasse |
| Everything else | medium | Safe default |

### Rules
- **Never default to high effort** — it should be explicitly triggered, not the fallback.
- **Fast mode** (`/fast` in Claude Code) runs Opus 4.8 at ~2.5× speed. Prefer it for any task where latency matters and correctness is not life-critical.
- **Effort ≠ quality** for most tasks. A low-effort Opus 4.8 response on a well-specified implementation task is better than a high-effort response on a vague one. Clarify the task first.
- **Re-evaluate effort mid-task**: if a subtask turns out simpler than expected, drop to low. If a subtask reveals unexpected complexity, escalate to high for that subtask only — not the whole session.
- **Token budget interaction**: high effort consumes more tokens per turn. If you are approaching the 200K session limit, prefer medium/low effort and checkpoint rather than burning the budget on extended thinking.
</effort-calibration>
"""

FAST_MODE_PATCH = "- **Never exceed 200K tokens** in one session."
FAST_MODE_REPLACEMENT = """\
- **Never exceed 200K tokens** in one session.
- **Prefer fast mode** (`/fast`) for Opus 4.8 tasks where correctness is not life-critical — 2.5× output speed at the same intelligence level."""


def patch_file(path: str) -> bool:
    with open(path) as f:
        content = f.read()

    original = content

    # 1. Replace <scope-update>...</scope-update> with corrected section
    pattern = re.compile(
        re.escape(OLD_SCOPE_TAG_OPEN) + r".*?" + re.escape(OLD_SCOPE_TAG_CLOSE),
        re.DOTALL,
    )
    if pattern.search(content):
        content = pattern.sub(NEW_MID_TASK_SECTION.rstrip(), content, count=1)

    # 2. Add <effort-calibration> after <mid-task-system-messages> (or at end)
    if "<effort-calibration>" not in content:
        if "</mid-task-system-messages>" in content:
            content = content.replace(
                "</mid-task-system-messages>",
                "</mid-task-system-messages>\n\n" + EFFORT_SECTION.rstrip(),
                1,
            )
        else:
            content = content.rstrip() + "\n\n" + EFFORT_SECTION.rstrip() + "\n"

    # 3. Patch token-budget section to mention fast mode
    if FAST_MODE_PATCH in content and FAST_MODE_REPLACEMENT not in content:
        content = content.replace(FAST_MODE_PATCH, FAST_MODE_REPLACEMENT, 1)

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
        path = os.path.join(AGENTS_DIR, fname)
        if patch_file(path):
            changed += 1
            print(f"  patched: agents/{fname}")
        else:
            skipped += 1

    genius_dir = os.path.join(AGENTS_DIR, "genius")
    for fname in sorted(os.listdir(genius_dir)):
        if not fname.endswith(".md"):
            continue
        path = os.path.join(genius_dir, fname)
        if patch_file(path):
            changed += 1
            print(f"  patched: agents/genius/{fname}")
        else:
            skipped += 1

    print(f"\nDone: {changed} patched, {skipped} skipped")


if __name__ == "__main__":
    main()
