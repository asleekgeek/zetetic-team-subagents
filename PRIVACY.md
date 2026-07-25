# Privacy Policy: zetetic-team-subagents / zetetic-gates

_Last updated: 2026-07-22_

Both plugins in this marketplace (the full agent system and the zetetic-gates
micro-plugin) are **local-only**. This policy states exactly what they read
and write, and what leaves your machine.

## What the plugins process

- **Agents, skills, commands, rules** are static Markdown loaded by Claude
  Code itself; they process nothing on their own.
- **Hooks and gate tools** (pre-commit zetetic checker, craftsmanship checker,
  secret-shield, lifecycle hooks) run local shell/Python subprocesses over the
  files in your working repository (staged diffs, file sizes, constants)
  and over local state under `~/.claude/`. Results go to your terminal and
  local state files only.
- **The memory tool** (full plugin only) stores notes locally under your home
  directory. No external database, no hosted service.

## What leaves your machine

**Nothing is transmitted by this plugin's own code.** No network calls, no
telemetry, no analytics. Note: some agents list Claude Code's own WebSearch /
WebFetch among their permitted tools: when *you* invoke such an agent and it
uses those tools, the resulting web requests are ordinary Claude Code tool
calls under your control and visibility, not plugin telemetry.

## Your controls

- Uninstall to remove all hooks and agents.
- Gate strictness is configured per-repo via `.craftsmanship.conf` /
  `ZETETIC_PROFILE`; hooks can be disabled per Claude Code's standard hook
  configuration.

## Contact

admin@ai-architect.tools · https://github.com/cdeust/zetetic-team-subagents/issues
