"""Put the repo root on sys.path so `import tools.acceptance_gate` resolves.

The module MUST be imported under its fully-qualified package path
(`tools.acceptance_gate`) — that is the key mutmut uses to match its trampoline
hits to mutants (rules/coding-standards.md §12). Importing it bare (as
`acceptance_gate`) makes every mutant look unreached and mutmut stops early.

Adding the repo root (parent of tools/ and tests/) works in two layouts with the
SAME code: the real repo, and mutmut's `mutants/` sandbox — mutmut copies
source_paths + also_copy preserving that sibling layout, so the path computed
from __file__ points at the MUTATED tools/acceptance_gate.py.
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))
