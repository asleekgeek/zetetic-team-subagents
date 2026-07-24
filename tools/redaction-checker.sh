#!/usr/bin/env bash
# redaction-checker.sh — Scan reader-facing Markdown copy for mechanically
# detectable AI-writing patterns.
#
# Usage:
#   tools/redaction-checker.sh --staged              # check staged .md changes (commit hook, warn-only)
#   tools/redaction-checker.sh --files <f1> <f2> ... # check specific files (review / CI)
#   tools/redaction-checker.sh --full                # scan all tracked copy paths (audit sweep)
#
# Checks (the greppable subset of skills/writing/redaction.md; judgment-level
# patterns — puffery, -ing analysis, colon reveals in context — stay with the
# skill, which is the authoritative inventory):
#   - EM_DASH  (warning): em dash in prose copy. House rule: zero in published copy.
#   - BANNED_WORD (warning): the skill's banned-outright vocabulary (§7).
#   - WEASEL (warning): unsourced-attribution and filler phrases (§5, §23).
#
# Severity model:
#   - All findings are WARNINGS by default: exit 0, findings on stdout. Prose
#     judgment belongs to a human or the /redaction skill; the mechanical layer
#     only surfaces candidates. ZETETIC_PROFILE=strict (via .zetetic.conf,
#     same contract as zetetic-checker.sh) makes findings exit 1.
#
# Scope: reader-facing copy only — README*, CHANGELOG*, docs/, top-level *.md.
# The pattern inventory itself, agent definitions, skills, templates, and test
# fixtures quote these patterns as examples and are always excluded.
#
# Exit codes: 0 clean (or warnings in default profile), 1 findings in strict, 2 usage error.
#
# Rule provenance: skills/writing/redaction.md (vendored from blader/humanizer
# v2.9.1 + petergyang/no-ai-slop, MIT; house deltas). Issue: #43.

set -euo pipefail

# ── Scope ──────────────────────────────────────────────────────────────
COPY_INCLUDE='(^|/)(README[^/]*|CHANGELOG[^/]*|CONTRIBUTING[^/]*|SECURITY[^/]*|PRIVACY[^/]*|CODE_OF_CONDUCT[^/]*)\.md$|^docs/.*\.md$'
COPY_EXCLUDE='^skills/|^agents/|^templates/|^tools/tests/|^tests/|^memory/|^rules/|node_modules/|^plugins/.*/(skills|agents)/'

# ── Patterns ───────────────────────────────────────────────────────────
# source: skills/writing/redaction.md §7 (banned vocabulary), §5 (weasel), §23 (filler), §14 (em dash)
EM_DASH_RE=$'—'
BANNED_RE='\b([Dd]elve|[Ff]oster(s|ing)?|[Ll]everag(e|es|ing)|[Uu]tiliz(e|es|ing)|[Ff]acilitat(e|es|ing)|[Ee]mpower(s|ing)?|[Ss]treamlin(e|es|ing)|[Rr]obust|[Cc]utting-edge|[Pp]aradigm shift|[Gg]ame.changer|[Tt]apestry|[Mm]ultifaceted|[Mm]eticulous|[Pp]aramount|[Tt]ransformative|[Ee]mbark(s|ing)?|[Ss]upercharg(e|es|ing)|[Hh]arness(es|ing)?|[Ee]ver-evolving)\b'
WEASEL_RE="([Ss]tudies show|[Ee]xperts (agree|argue|believe)|[Ii]ndustry reports|[Ww]idely regarded|[Ii]t.s worth noting|[Ii]t.s important to note|[Ii]n today.s world|[Aa]t the end of the day|[Ll]et.s dive in|[Ii]n the ever-|[Gg]ame.changing)"

# ── Profile (same contract as zetetic-checker.sh: declared, not env-silent) ──
ZETETIC_PROFILE="${ZETETIC_PROFILE:-standard}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -f "$repo_root/.zetetic.conf" ]]; then
  profile_line=$(grep -E '^[[:space:]]*ZETETIC_PROFILE=' "$repo_root/.zetetic.conf" | tail -1 || true)
  [[ -n "$profile_line" ]] && ZETETIC_PROFILE="${profile_line#*=}"
fi

# ── File selection ─────────────────────────────────────────────────────
mode="${1:-}"
files=()
case "$mode" in
  --staged)
    while IFS= read -r f; do files+=("$f"); done \
      < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E "$COPY_INCLUDE" | grep -Ev "$COPY_EXCLUDE" || true)
    ;;
  --files)
    shift
    [[ $# -eq 0 ]] && { echo "usage: $0 --files <f1> [f2 ...]" >&2; exit 2; }
    for f in "$@"; do
      if echo "$f" | grep -qE "$COPY_INCLUDE" && ! echo "$f" | grep -qE "$COPY_EXCLUDE"; then
        files+=("$f")
      fi
    done
    ;;
  --full)
    while IFS= read -r f; do files+=("$f"); done \
      < <(git ls-files 2>/dev/null | grep -E "$COPY_INCLUDE" | grep -Ev "$COPY_EXCLUDE" || true)
    ;;
  *)
    echo "usage: $0 --staged | --files <f...> | --full" >&2
    exit 2
    ;;
esac

[[ ${#files[@]} -eq 0 ]] && exit 0

# ── Scan ───────────────────────────────────────────────────────────────
findings=0
scan_file() {
  local f="$1" in_fence=0 lineno=0 line
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # skip fenced code blocks — code and quoted commands aren't copy
    if [[ "$line" =~ ^\`\`\` ]]; then in_fence=$((1 - in_fence)); continue; fi
    [[ $in_fence -eq 1 ]] && continue
    if printf '%s' "$line" | grep -q "$EM_DASH_RE"; then
      echo "$f:$lineno: EM_DASH: house rule is zero em dashes in copy (redaction §14)"
      findings=$((findings + 1))
    fi
    if printf '%s' "$line" | grep -qE "$BANNED_RE"; then
      echo "$f:$lineno: BANNED_WORD: $(printf '%s' "$line" | grep -oE "$BANNED_RE" | head -1) (redaction §7)"
      findings=$((findings + 1))
    fi
    if printf '%s' "$line" | grep -qE "$WEASEL_RE"; then
      echo "$f:$lineno: WEASEL: $(printf '%s' "$line" | grep -oE "$WEASEL_RE" | head -1) — name the source or cut (redaction §5/§23)"
      findings=$((findings + 1))
    fi
  done < "$f"
}

for f in "${files[@]}"; do scan_file "$f"; done

if [[ $findings -gt 0 ]]; then
  echo "redaction: $findings candidate pattern(s) in reader-facing copy. Authoritative inventory: skills/writing/redaction.md"
  if [[ "$ZETETIC_PROFILE" == "strict" ]]; then
    exit 1
  fi
fi
exit 0
