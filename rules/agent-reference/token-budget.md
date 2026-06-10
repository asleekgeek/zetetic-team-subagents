---
name: token-budget
description: "Full token-budget protocol: per-model limits table, checkpoint procedure and template, memory store/recover rules, session chunking"
read_when: "The first time your running token estimate approaches your checkpoint threshold"
audience: team agents — loaded on demand via Read, never at spawn
---

## Token Budget Protocol

### Model limits (authoritative)

| Model | Context window | Max output | Session budget (hard cap) | Checkpoint threshold |
|---|---|---|---|---|
| Claude Fable 5 | 1,000K | — | 160K | ~120K |
| Claude Opus 4.8 | 1,000K | 128K | 200K | ~180K |
| Claude Sonnet 4.6 | 1,000K | 64K | 200K | ~180K |
| Claude Haiku 4.5 | 200K | 64K | 170K | ~120K |

**Your model and threshold are named in your core file's `<token-budget>` stub** (declared per agent; authoritative values in `~/.claude/ctxguard-thresholds.json`). Apply the corresponding row above.

The session budget is a conservative cap that keeps sessions focused and memory-checkpointed; it is not the model's physical context limit (except for Haiku, whose window IS 200K — the 170K cap leaves headroom for the checkpoint turn itself). Fable 5 caps earlier (160K) because it pays ~2x Opus rates: carrying rent and the 5-minute cache-expiry resume penalty bite twice as hard. The authoritative per-model values live in `~/.claude/ctxguard-thresholds.json`, shared by the Stop guard hook and the session-optimizer statusline; this table mirrors it.

### Checkpoint procedure — trigger at threshold

When your running token estimate reaches the threshold:

**Step 1 — Store state to memory**
```bash
MEMORY_AGENT_ID=<agent-id> tools/memory-tool.sh create   /memories/<scope>/checkpoint.md "$(cat <<'CHECKPOINT'
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
Resume from: /memories/<scope>/checkpoint.md
Next action: <copy from checkpoint's "Next action" field>
```

**Step 3 — On restart, recover before anything else**
```bash
# First act — no exceptions
MEMORY_AGENT_ID=<agent-id> tools/memory-tool.sh view /memories/<scope>/
# Then load the checkpoint:
MEMORY_AGENT_ID=<agent-id> tools/memory-tool.sh view /memories/<scope>/checkpoint.md
```
Read the checkpoint fully before touching any file, tool, or search.

### Memory store rules
- Store **decisions and state**, not code. Code belongs in the repo.
- Keep checkpoint files under 50K (the tool rejects >100K).
- One checkpoint file per task; overwrite it as you progress.
- Cross-session notes (rejected approaches, confirmed constraints) go in a separate `/memories/<scope>/notes.md`.

### Memory recover rules
- Checkpoint is ground truth. If the checkpoint contradicts your current context, trust the checkpoint.
- Verify file state with `Read` after recovery — don't assume files match what the checkpoint describes.
- If the checkpoint references a file that no longer exists, note the discrepancy and adapt.

### Additional rules
- **Never exceed the threshold in a single session.** Prefer multiple focused sessions.
- **Prefer fast mode** (`/fast`) for Opus 4.8 tasks where peak correctness is not required — 2.5× speed ($10/$50 MTok fast mode vs $5/$25 standard).
- **Output budget**: reserve at least 10K output tokens for your final response. For Opus, headroom is generous (128K). For Sonnet and Haiku (both 64K), avoid sessions where a single long response might exhaust output budget.
- **Complex tasks**: chunk into sub-sessions of ≤150K each; record the chunk plan in memory before starting.
