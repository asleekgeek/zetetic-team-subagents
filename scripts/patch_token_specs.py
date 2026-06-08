#!/usr/bin/env python3
"""
Patch 5: Correct token specs and memory store/recover protocol.

Corrections:
- Sonnet 4.6: max output = 64K (was "—")
- Haiku 4.5: max output = 64K (was "—"), context = 200K
- Haiku checkpoint threshold: ~120K (not 180K) — at 136K context, only 64K
  output space remains, which is the hard output ceiling
- Precise memory store/recover commands in <token-budget>
- Model spec table updated with Max output row
"""
import os
import re

AGENTS_DIR = os.path.join(os.path.dirname(__file__), "..", "agents")

# The full replacement for <token-budget>...</token-budget>
# We'll produce model-specific versions for haiku vs others

TOKEN_BUDGET_OPUS_SONNET = """\
<token-budget>
## Token Budget Protocol

### Model limits (authoritative)

| Model | Context window | Max output | Session budget (soft cap) | Checkpoint threshold |
|---|---|---|---|---|
| Claude Opus 4.8 | 1,000K | 128K | 200K | ~180K |
| Claude Sonnet 4.6 | 1,000K | 64K | 200K | ~180K |
| Claude Haiku 4.5 | 200K | 64K | 200K (= context limit) | ~120K |

**This agent runs on {MODEL}.** Apply the corresponding threshold above.

The 200K session budget is a conservative soft cap that keeps sessions focused and memory-checkpointed. It is not the model's physical context limit (except for Haiku, where they coincide).

### Checkpoint procedure — trigger at threshold

When your running token estimate reaches the threshold:

**Step 1 — Store state to memory**
```bash
MEMORY_AGENT_ID={AGENT_ID} tools/memory-tool.sh create \
  /memories/{SCOPE}/checkpoint.md "$(cat <<'CHECKPOINT'
## Checkpoint <ISO-date>

### Task
<one sentence: what the overall task is>

### Completed
- <item 1>
- <item 2>

### In progress
- <item and exact state>

### Remaining
- <item 1>
- <item 2>

### Key decisions made
- <decision and rationale>

### Files modified
- <path>: <what changed>

### Next action
<exact first thing to do on restart>
CHECKPOINT
)"
```

**Step 2 — Signal session end**

End your response with exactly:
```
CHECKPOINT — context cleared.
Resume from: /memories/{SCOPE}/checkpoint.md
Next action: <copy from checkpoint's "Next action" field>
```

**Step 3 — On restart, recover before anything else**
```bash
# First act — no exceptions
MEMORY_AGENT_ID={AGENT_ID} tools/memory-tool.sh view /memories/{SCOPE}/
# Then load the checkpoint:
MEMORY_AGENT_ID={AGENT_ID} tools/memory-tool.sh view /memories/{SCOPE}/checkpoint.md
```
Read the checkpoint fully before touching any file, tool, or search.

### Memory store rules
- Store **decisions and state**, not code. Code belongs in the repo.
- Keep checkpoint files under 50K (the tool rejects >100K).
- One checkpoint file per task; overwrite it as you progress.
- Cross-session notes (rejected approaches, confirmed constraints) go in a separate `/memories/{SCOPE}/notes.md`.

### Memory recover rules
- Checkpoint is ground truth. If the checkpoint contradicts your current context, trust the checkpoint.
- Verify file state with `Read` after recovery — don't assume files match what the checkpoint describes.
- If the checkpoint references a file that no longer exists, note the discrepancy and adapt.

### Additional rules
- **Never exceed the threshold in a single session.** Prefer multiple focused sessions.
- **Prefer fast mode** (`/fast`) for Opus 4.8 tasks where peak correctness is not required — 2.5× speed ($10/$50 MTok fast vs $5/$25 standard).
- **Output budget**: reserve at least 10K output tokens for your final response. For Opus, headroom is generous (128K). For Sonnet and Haiku (both 64K), avoid sessions where a single long response might exhaust output budget.
- **Complex tasks**: chunk into sub-sessions of ≤150K each; record the chunk plan in memory before starting.
</token-budget>
"""

TOKEN_BUDGET_HAIKU = """\
<token-budget>
## Token Budget Protocol

### Model limits (authoritative)

| Model | Context window | Max output | Session budget | Checkpoint threshold |
|---|---|---|---|---|
| Claude Haiku 4.5 | **200K** | **64K** | 200K (= context limit) | **~120K** |

**This agent runs on Haiku 4.5.** The 200K session budget equals the model's physical context limit — there is no slack. At 136K context tokens consumed, only 64K of output space remains (the hard output ceiling). The 120K threshold gives ~16K buffer above that boundary.

### Checkpoint procedure — trigger at ~120K tokens

**Step 1 — Store state to memory**
```bash
MEMORY_AGENT_ID=haiku tools/memory-tool.sh create \
  /memories/{SCOPE}/checkpoint.md "$(cat <<'CHECKPOINT'
## Checkpoint <ISO-date>

### Task
<one sentence: what the overall task is>

### Completed
- <item 1>

### In progress
- <item and exact state>

### Remaining
- <item 1>

### Key decisions made
- <decision and rationale>

### Files modified
- <path>: <what changed>

### Next action
<exact first thing to do on restart>
CHECKPOINT
)"
```

**Step 2 — Signal session end**
```
CHECKPOINT — context cleared.
Resume from: /memories/{SCOPE}/checkpoint.md
Next action: <copy from checkpoint's "Next action" field>
```

**Step 3 — On restart, recover before anything else**
```bash
MEMORY_AGENT_ID=haiku tools/memory-tool.sh view /memories/{SCOPE}/
MEMORY_AGENT_ID=haiku tools/memory-tool.sh view /memories/{SCOPE}/checkpoint.md
```

### Memory store rules
- Store decisions and state, not code. Code belongs in the repo.
- Keep checkpoint files under 50K (tool rejects >100K).
- One checkpoint file per task; overwrite as you progress.

### Memory recover rules
- Checkpoint is ground truth over current context.
- Verify file state with `Read` after recovery.
- Adapt if a referenced file no longer exists.

### Additional rules
- **Hard ceiling**: never consume past 180K context — at that point only 20K output remains, not enough for a useful response.
- **Output budget**: 64K max output is shared with tool call responses. Large file reads count. Keep individual responses under 30K when possible.
- **Haiku is designed for pre-planned execution.** If a task requires significant reasoning not in the original plan, escalate to the orchestrator (Sonnet or Opus) rather than burning Haiku's limited context on reasoning.
</token-budget>
"""

EFFORT_TABLE_OLD = """\
| Model | Context | Output | Cost (in/out MTok) | Latency | Best for |
|---|---|---|---|---|---|
| Claude Opus 4.8 | 1M | 128K | $5 / $25 | ~77 TPS | Hardest work, peak intelligence, sustained autonomy |
| Claude Sonnet 4.6 | 1M | — | $3 / $15 | ~72 TPS | Building & iterating — coding workflows, agent prototyping |
| Claude Haiku 4.5 | **200K** | — | $1 / $5 | ~109 TPS | Executing pre-planned tasks, latency-sensitive, cost-sensitive |"""

EFFORT_TABLE_NEW = """\
| Model | Context | Max output | Cost (in/out MTok) | Latency | Best for |
|---|---|---|---|---|---|
| Claude Opus 4.8 | 1M | **128K** | $5 / $25 | ~77 TPS | Hardest work, peak intelligence, sustained autonomy |
| Claude Sonnet 4.6 | 1M | **64K** | $3 / $15 | ~72 TPS | Building & iterating — coding workflows, agent prototyping |
| Claude Haiku 4.5 | **200K** | **64K** | $1 / $5 | ~109 TPS | Executing pre-planned tasks, latency-sensitive, cost-sensitive |"""

HAIKU_NOTE_OLD = "**Haiku context limit is a hard technical constraint**: Haiku 4.5 has a 200K context window — identical to the session token budget. For haiku agents, the 200K checkpoint protocol is not advisory; it is the model's physical limit."
HAIKU_NOTE_NEW = "**Haiku 4.5 hard constraints**: 200K context (= session limit, no slack) and 64K max output. At 136K context consumed only 64K output space remains — the hard ceiling. Haiku checkpoint triggers at ~120K, not 180K. Sonnet and Opus also have 64K max output (Opus: 128K); both run on 1M context so the 200K session budget is a conservative soft cap."


def get_model_label(name: str, is_genius: bool) -> tuple[str, str]:
    """Return (MODEL_LABEL, AGENT_ID_HINT, SCOPE_HINT) for template substitution."""
    if is_genius or name in {"orchestrator", "architect", "security-auditor"}:
        return "Opus 4.8", name if not is_genius else f"genius-{name}"
    haiku_agents = {"latex-engineer", "professor"}
    if name in haiku_agents:
        return "Haiku 4.5", name
    return "Sonnet 4.6", name


TOKEN_BUDGET_PATTERN = re.compile(
    r"<token-budget>.*?</token-budget>", re.DOTALL
)


def patch_file(path: str, name: str, is_genius: bool) -> bool:
    with open(path) as f:
        content = f.read()

    original = content

    model_label, agent_id_hint = get_model_label(name, is_genius)[:2]
    scope = "genius" if is_genius else name

    # 1. Replace <token-budget> section
    if model_label == "Haiku 4.5":
        new_budget = TOKEN_BUDGET_HAIKU.replace("{SCOPE}", scope)
    else:
        new_budget = (
            TOKEN_BUDGET_OPUS_SONNET
            .replace("{MODEL}", model_label)
            .replace("{AGENT_ID}", agent_id_hint)
            .replace("{SCOPE}", scope)
        )

    if TOKEN_BUDGET_PATTERN.search(content):
        content = TOKEN_BUDGET_PATTERN.sub(new_budget.rstrip(), content, count=1)
    elif "<token-budget>" not in content:
        content = content.rstrip() + "\n\n" + new_budget.rstrip() + "\n"

    # 2. Fix effort table (output column was "—")
    content = content.replace(EFFORT_TABLE_OLD, EFFORT_TABLE_NEW)

    # 3. Fix haiku callout note
    content = content.replace(HAIKU_NOTE_OLD, HAIKU_NOTE_NEW)

    # 4. Fix leftover fast mode pricing string from patch 2
    content = content.replace(
        "2.5× speed ($10/$50 MTok fast vs $5/$25 standard).",
        "2.5× speed ($10/$50 MTok fast mode vs $5/$25 standard).",
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
        path = os.path.join(AGENTS_DIR, fname)
        if patch_file(path, fname[:-3], is_genius=False):
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
