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

**Step 1 — Store state to memory** (letta summary schema — goals / file references / errors and fixes / current state / next steps; ≤500 words total, quoted tool outputs clipped to 2,000 chars)
```bash
MEMORY_AGENT_ID=<agent-id> tools/memory-tool.sh create   /memories/<scope>/checkpoint.md "$(cat <<'CHECKPOINT'
---
description: "<one-line retrieval cue for this checkpoint — MANDATORY; the tool rejects .md files without it>"
---
## Checkpoint <ISO-date>

### Goals
<what this session is trying to achieve, in priority order>

### File references
- <path>:<start>-<end> — <why the resumed session needs it>

### Errors and fixes
- <error hit this session> → <how it was fixed or worked around>

### Current state
<one paragraph: where the work stands right now — completed, in progress, remaining>

### Next steps
1. <exact first action on restart — executable without re-deriving anything>
2. <subsequent ordered actions>
CHECKPOINT
)"
```
Use `rethink` instead of `create` to overwrite an existing checkpoint (optionally with a CAS sha from `memory-tool.sh sha <path>` when your scope is shared).

**Step 2 — Signal session end**

End your response with exactly:
```
CHECKPOINT — context cleared.
Resume from: /memories/<scope>/checkpoint.md
Next action: <copy from checkpoint's first "Next steps" entry>
```

**Step 3 — On restart, recover before anything else**
```bash
# First act — no exceptions
MEMORY_AGENT_ID=<agent-id> tools/memory-tool.sh view /memories/<scope>/
# Then load the checkpoint:
MEMORY_AGENT_ID=<agent-id> tools/memory-tool.sh view /memories/<scope>/checkpoint.md
```
**Resume contract:** read the checkpoint + ONE targeted, agent_topic-scoped `cortex:recall`. Do NOT re-read files or docs the checkpoint already summarizes — trust its file references; verify with targeted Reads only when editing.

### Memory store rules
- Store **decisions and state**, not code. Code belongs in the repo.
- Keep checkpoint files ≤500 words (hard tool cap is 100K bytes; the schema budget is the binding one).
- Every memory `.md` file begins with frontmatter carrying `description:` — it is the retrieval cue; the tool rejects files without it.
- One checkpoint file per task; `rethink` it as you progress.
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
