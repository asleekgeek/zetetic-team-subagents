#!/usr/bin/env python3
"""
Patch 7: Replace <memory-architecture> with Cortex-precise version.

Previous version described Letta concepts accurately but was imprecise
about how Cortex actually implements them. This patch replaces it with
facts derived directly from reading the Cortex source.

Key corrections:
- Local /memories/<scope>/ = authoritative synchronous write layer (NOT "Tier 2")
- Cortex DB = eventually-consistent semantic index fed via .pending-sync queue
  (NOT an independent tier — same logical store, different access pattern)
- session_start hook is the progressive disclosure mechanism
- Compaction hook (compaction_checkpoint.py) already auto-saves checkpoints
- Dream cycle at session end = consolidation (Borbely 1982 / Tononi & Cirelli 2003)
- Wiki = separate system for durable documentation, NOT memory
"""
import os
import re

AGENTS_DIR = os.path.join(os.path.dirname(__file__), "..", "agents")

OLD_SECTION_PATTERN = re.compile(
    r"<memory-architecture>.*?</memory-architecture>",
    re.DOTALL,
)

NEW_MEMORY_ARCH = """\
<memory-architecture>
## Cortex Memory Architecture — How It Actually Works

Three surfaces, two stores, one sync queue. Know what each one is before writing to it.

```
SESSION START (session_start.py hook)
  → loads: anchored memories + hot memories (heat ≥ 0.4) + latest checkpoint
  → injects as Markdown block into context (progressive disclosure)
  → this IS the "system memory" equivalent — pinned at spawn

DURING SESSION
  ├── LOCAL FS  ~/.claude/memories/<scope>/   ← synchronous, authoritative
  │     ├── checkpoint.md                      ← overwrite as task progresses
  │     ├── notes.md                           ← constraints, rejected approaches
  │     └── scope-history.md                  ← scope deltas received mid-task
  │
  └── .pending-sync/ queue                    ← async bridge to Cortex DB
        (every memory-tool.sh write enqueues a job here)

CORTEX DB (PostgreSQL + pgvector)             ← eventually consistent replica
  ├── cortex:remember → writes episodic/semantic memories with embeddings
  ├── cortex:recall   → hybrid WRRF retrieval (vector + FTS + heat + recency)
  └── fed by drain-sync from .pending-sync queue (local FS is authoritative)

SESSION END (session_lifecycle.py hook)
  → records session stats
  → runs dream cycle: <5 turns=decay; 5-20=decay+compress; >20=full CLS replay
  → this is the consolidation step — episodic → semantic promotion

COMPACTION (compaction_checkpoint.py hook — fires automatically)
  → saves hippocampal checkpoint before context compaction
  → increments epoch, runs cascade advancement
  → you do NOT need to manually checkpoint at compaction — it happens
```

### The two stores and their relationship

**Local FS** (`~/.claude/memories/<scope>/`) is the fast, synchronous write surface. Every `tools/memory-tool.sh create` or `str_replace` is immediately durable. This is your working memory — the place to write decisions, state, and checkpoints during a task.

**Cortex DB** (PostgreSQL/pgvector) is the semantic search surface. It is an eventually-consistent replica of local FS, fed via the `.pending-sync` queue. When you call `cortex:recall`, you are querying the DB. When you call `cortex:remember` directly, you bypass local FS and write straight to the DB. The two stores converge but are not identical at any given moment.

**Rule**: Write task-state to local FS (`memory-tool.sh create`). The sync queue will replicate it to Cortex DB asynchronously. Do not verify a local write via `cortex:recall` — the sync queue may not have drained yet. Use `memory-tool.sh view` to verify local writes.

### What "system memory" means here

The Cortex session_start hook injects hot+anchored memories and the latest checkpoint into context at spawn. This is the pinned layer — it is loaded once and cached. The agent `.md` file (this file) is also loaded once and cached as the system prompt.

**Neither should be modified mid-session.** Modifying the system prompt mid-session busts the KV cache (full context reload cost). Hot memory injection at session start is handled by the hook — not by the agent.

**Opus 4.8 exception**: Mid-conversation `"system"` role messages (injected by the harness/orchestrator) are cache-safe incremental updates that do not modify the top-level system prompt. Use these for token-budget updates, permission changes, and scope narrowing. You receive them; you do not send them.

### What to write where

| Situation | Write to | Tool |
|---|---|---|
| Task progress, current state, next action | `/memories/<scope>/checkpoint.md` | `memory-tool.sh create/str_replace` |
| Rejected approach or confirmed constraint | `/memories/<scope>/notes.md` | `memory-tool.sh create/str_replace` |
| Mid-task scope change received | `/memories/<scope>/scope-history.md` | `memory-tool.sh create` |
| Insight worth surfacing across ALL future sessions | `cortex:remember` directly (tags, agent_topic) | MCP tool |
| Cross-session architecture or design knowledge | Wiki (`cortex:wiki_write`) | MCP tool |
| Cross-agent lesson | Propose to orchestrator — you cannot write `/memories/lessons/` | — |

### Cortex recall vs memory-tool.sh search

| Surface | Command | When to use |
|---|---|---|
| `memory-tool.sh view` | `view /memories/<scope>/file.md` | Known path — deterministic, fast |
| `memory-tool.sh search` | `search "<query>" --scope <name>` | Known keyword, unknown file |
| `cortex:recall` | MCP tool, query string | Conceptual/semantic retrieval across sessions |

Never use `cortex:recall` to verify a write you just made. It is async. Use `memory-tool.sh view`.

### Wiki vs memory

Wiki (`cortex:wiki_write`, `wiki_read`) is a **separate durable documentation surface** — markdown files at `~/.claude/methodology/wiki/` backed by `wiki.pages` table. It is never pruned. Use it for ADRs, specs, and long-form reference. It is NOT memory — it does not decay, does not have heat scores, and is not subject to dream-cycle consolidation. Wiki pages are indexed back into memory as protected pointer entries so `recall` can surface them, but the wiki itself lives outside the memory lifecycle.
</memory-architecture>
"""


def patch_file(path: str) -> bool:
    with open(path) as f:
        content = f.read()

    original = content

    if OLD_SECTION_PATTERN.search(content):
        content = OLD_SECTION_PATTERN.sub(NEW_MEMORY_ARCH.rstrip(), content, count=1)
    elif "<memory-architecture>" not in content:
        # Shouldn't happen after patch 6, but handle gracefully
        if "\n<memory>" in content:
            content = content.replace(
                "\n<memory>",
                "\n" + NEW_MEMORY_ARCH.rstrip() + "\n\n<memory>",
                1,
            )
        else:
            content = content.rstrip() + "\n\n" + NEW_MEMORY_ARCH.rstrip() + "\n"

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
