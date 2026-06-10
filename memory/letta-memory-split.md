# Letta Memory Split — Reverse-Engineering Reference

Source: letta-ai/letta + letta-ai/letta-code, shallow-cloned and read 2026-06-10
(`/tmp/letta-re/`). Letta is **reference only, never a dependency** — this doc
records the pattern we replicate over our own stack (memory-tool.sh + Cortex).
File:line citations refer to the cloned trees at that date.

## The three tiers (letta server)

| Tier | Content | Write path | Properties |
|---|---|---|---|
| **Core blocks** (system memory) | persona / human / agent-defined blocks — the agent's self-model, user-model, working state | Block verbs only: `core_memory_append/replace`, `memory_insert/replace/rethink/apply_patch` (`letta/functions/function_sets/base.py:246-517`) | Always in-context (rendered into the system prompt via `{CORE_MEMORY}`, `letta/prompts/prompt_generator.py:106-177`); size-capped — persona/human 20K chars, generic 100K (`letta/constants.py:433-435`); XML-rendered with `chars_current`/`chars_limit` metadata (`letta/schemas/memory.py:142-203`) |
| **Recall** | Raw conversation history (every message) | Auto-captured per turn; agent **cannot write it** | Read-only; searched via `conversation_search` (`base.py:87-161`), hybrid text+semantic, tool messages filtered out |
| **Archival** (agent memory) | Self-contained facts, summaries, events — explicitly curated | `archival_memory_insert(content, tags)` (`base.py:164-191`) | Out-of-context; embedded passages with tags + timestamps (`letta/orm/passage.py:76-104`); searched semantically via `archival_memory_search` with tag filters (`base.py:194-242`); unlimited, permanent |

## The split rule (quoted from letta prompts/tool docs)

- Core memory: *"held inside the initial system instructions file, and is
  always available in-context … memory blocks are limited in size"*
  (`letta/prompts/system_prompts/memgpt_v2_chat.py:52-55`).
- Archival best practices (`base.py:172-176`): *"Store self-contained facts or
  summaries, not conversational fragments. Add descriptive tags … Use for:
  meeting notes, project updates, conversation summaries, events, reports."*
- Sleeptime curation (`letta/prompts/system_prompts/sleeptime_v2.py:24`):
  *"Not every observation warrants a memory edit, be selective in your memory
  editing, but also aim to have high recall."* The sleeptime agent edits **core
  blocks only** with `memory_replace/insert/rethink` (`sleeptime_v2.py:14-16`);
  it shares the foreground agent's blocks and runs async after turns
  (`letta/groups/sleeptime_multi_agent_v4.py:132-168`).

Net rule: **personality/relationship/working-state stays in size-capped core
blocks; discrete facts and summaries go to archival; raw history is recall and
is never a write target.**

## letta-code specifics

- Two global blocks only: `persona`, `human`
  (`letta-code/src/agent/memory.ts:13`); project block exists as a template but
  is not auto-initialized; skills were **removed from memory** and moved to
  system reminders (`memory.ts:41`, LET-7353).
- Block storage is git-backed files under `~/.letta/agents/<id>/memory/` with
  commit-on-write and the agent as commit author
  (`letta-code/src/tools/impl/memory.ts:121-131`,
  `src/agent/memory-filesystem.ts:26-53`) — an audit trail per memory edit.
- A read-only `memory_filesystem` block renders the memory directory tree into
  context (`src/agent/memory-constants.ts:1`) — system-managed, not
  agent-writable.

## Mapping onto our stack

| letta | ours | status |
|---|---|---|
| Core blocks (persona/human/state) | Scoped FS files `/memories/<scope>/{checkpoint,notes}.md` via memory-tool.sh verbs (`create/str_replace/insert/rethink`, CAS `sha`) | ✅ same verbs, size caps (§6), git-like audit via `.audit.log` |
| Block rendering into system prompt | session_start hook injection (anchored + hot + latest checkpoint) | ⚠ must inject **blocks**, not raw captures |
| Recall (auto conversation history) | Cortex auto-captured session/tool events | ⚠ read-only tier — never a curated-memory source |
| Archival insert w/ tags | `cortex:remember` with mandatory `archival` tag + `agent_topic` | ⚠ tag discipline added in contract §8b |
| Sleeptime agent (block curator) | `memory-writer` subagent at context-guard WARN | ✅ same trigger shape (async-ish, cheap model, selective) |
| `archival_memory_search` | scoped `cortex:recall` | ✅ |

The failure mode this doc exists to prevent: funneling **both** tiers through a
flat `cortex:remember` so block-state, archival facts, and auto-captured tool
events all rank together at recall time (observed 2026-06-10: raw `# Tool:
Edit` captures surfacing beside curated decisions in session-start hot
memories). The write rule is normative in `memory/contract.md §8b`.
