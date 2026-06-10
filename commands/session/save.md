# Save Session Context

Save the current session's context for future recall.

## Instructions

1. Summarize the current session: decisions made, files changed, open questions, difficulty-book state.

2. **Session state is a block, not an archival fact** (memory/contract.md §8b). Write the summary to the scoped working-state block:
   `MEMORY_AGENT_ID=<your-scope-or-_user> tools/memory-tool.sh rethink /memories/<scope>/checkpoint.md "<summary>"` (use `create` for the first checkpoint of a scope). The §8a sync drainer replicates it to Cortex tagged `memory-replica` automatically — do NOT call `cortex:remember` for the session summary itself.

3. If (and only if) the session produced self-contained WHY-level facts — a decision with its rationale, a rejected approach with its root cause, a lesson — store each one via `cortex:remember` with `tags: ["archival", "<project-name>", ...]` AND `agent_topic`. Be selective: not every observation warrants an archival entry.

4. Also save locally: `tools/session-store.sh save "<summary>"`

5. Confirm to the user what was saved (block path + number of archival entries, if any).

$ARGUMENTS
