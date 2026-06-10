# Genius Agent Index

Display the genius agent index in a navigable format. Filter by category, show pairings, or browse the full shape-to-agent lookup.

## Instructions

1. Parse $ARGUMENTS for optional filters:
   - No arguments: show all categories with agent counts
   - `index <category>` — show shapes for a specific category (fuzzy match on category name)
   - `index --agents` — list all agents with their descriptions
   - `index --pairs <agent>` — show what pairs well with a given agent
   - `index --search <term>` — search shapes, triggers, and agents by keyword

2. **Category overview** (no args): Do NOT Read INDEX.md whole (132KB). Run `grep -n '^### ' agents/genius/INDEX.md` for the category headers and count table rows per category with a targeted `awk`/`grep`. Display as a numbered list:
   ```
   1. Measurement, Signal, and Isolation (5 shapes) — curie
   2. Estimation and Bounding (5 shapes) — fermi
   ...
   ```
   Tell the user they can drill into any category by number or name.

3. **Category detail**: Extract only the matching `### ` section from INDEX.md (case-insensitive partial match) with a targeted `sed`/`awk` range — never a full-file Read. Display the full shape table for that category. Include the trigger and key move columns for each shape.

4. **Agent list**: Read `rules/agent-routing-table.md` (compact generated table, ~25KB) or run `tools/genius-invoker.sh list --shapes`. Format as a clean table with agent name, description, and shapes.

5. **Pairs**: Extract the `pairs_well_with` frontmatter field with `sed -n '1,/^---$/p' agents/genius/<agent>.md` (frontmatter only — not the full file). For each paired agent, show its description from `rules/agent-routing-table.md`. Suggest composition patterns using `/genius-compose`.

6. **Search**: Run `tools/genius-invoker.sh list --search "<term>"`. Also grep INDEX.md for matching shapes (`grep -i '<term>' agents/genius/INDEX.md`). Combine results, deduplicating by agent name.

7. Always end with a usage hint: how to invoke an agent (`/genius-invoke <name> "<problem>"`), how to compose agents (`/genius-compose`), or how to let the router pick (`/genius-route`).

$ARGUMENTS
