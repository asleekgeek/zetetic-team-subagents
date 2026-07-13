#!/usr/bin/env bash
# worktree-manager.sh — Manage agent worktrees
#
# Usage:
#   tools/worktree-manager.sh list                  # show active agent worktrees
#   tools/worktree-manager.sh cleanup               # remove merged agent/* worktrees (this repo)
#   tools/worktree-manager.sh status <agent-name>   # show last commit in worktree
#   tools/worktree-manager.sh sweep [--fetch] [repo ...]
#                                                    # remove merged tmp worktrees + stale
#                                                    # branches across one or more repos
#
# sweep contract:
#   - No repo args: discovers top-level git repos under the parent of this
#     repo (skips linked worktrees, identified by a `.git` FILE, not a dir).
#   - --fetch: runs `git fetch origin --prune` first (never on by default —
#     session-start calls sweep without it to avoid network at boot).
#   - A worktree is removed only if: its path is under /tmp or /private/tmp
#     (never a deliberate ~/Developments worktree), its branch is not
#     `live/*` (dev-symlink targets), its tip is an ancestor of origin/main,
#     and its working tree is clean. Removal never uses --force; branch
#     deletion never uses -D.
#   - After worktree removal, local branches merged into origin/main with no
#     worktree (excluding main/master/live/*/checked-out branches) are
#     deleted with `git branch -d`.
#
# Exit codes: 0 success, 1 error, 2 usage error

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ACTION="${1:-}"; AGENT="${2:-}"

[[ -z "$ACTION" ]] && { echo "usage: $0 <list|cleanup|status|sweep> [args]" >&2; exit 2; }

# --- sweep helpers --------------------------------------------------------

# Prints "<path>\t<branch>" one per worktree (branch empty/"(detached)" if unnamed).
list_worktrees() {
  local repo="$1"
  git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { if (path != "") print path "\t" branch;
                   path=$2; branch="" }
    /^branch /   { b=$2; sub("refs/heads/", "", b); branch=b }
    /^detached$/ { branch="(detached)" }
    END { if (path != "") print path "\t" branch }
  '
}

# Removes merged, clean, tmp-path worktrees for one repo. Echoes one line per
# decision. Returns 1 only on an unexpected command failure, not on skips.
sweep_worktrees() {
  local repo="$1" primary="$2" primary_branch="$3"
  local removed=0 path branch rc=0
  while IFS=$'\t' read -r path branch; do
    [[ -z "$path" ]] && continue
    path="$(cd "$path" 2>/dev/null && pwd || echo "$path")"
    [[ "$path" == "$primary" ]] && continue

    if [[ -z "$branch" || "$branch" == "(detached)" ]]; then
      echo "  skip $path: detached HEAD"; continue
    fi
    if [[ "$branch" == "$primary_branch" ]]; then
      echo "  skip $path: current branch of primary worktree"; continue
    fi
    if [[ "$branch" == live/* ]]; then
      echo "  skip $path: protected branch ($branch)"; continue
    fi
    case "$path" in
      /tmp/*|/private/tmp/*) ;;
      *) echo "  skip $path: not under /tmp (deliberate worktree)"; continue ;;
    esac
    if ! git -C "$repo" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
      echo "  skip $path ($branch): not merged into origin/main"; continue
    fi
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      echo "  skip $path ($branch): dirty working tree"; continue
    fi

    echo "  remove $path ($branch): merged + clean"
    if git -C "$repo" worktree remove "$path" 2>/dev/null; then
      git -C "$repo" branch -d "$branch" 2>/dev/null || true
      removed=$((removed + 1))
    else
      echo "  error: worktree remove failed for $path"
      rc=1
    fi
  done < <(list_worktrees "$repo")
  echo "  removed: $removed worktree(s)"
  return "$rc"
}

# Deletes local branches merged into origin/main with no attached worktree.
sweep_stale_branches() {
  local repo="$1"; shift
  local kept=("$@") branch deleted=0

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    case "$branch" in main|master|live/*) continue ;; esac
    local skip=0 k
    for k in "${kept[@]}"; do [[ "$branch" == "$k" ]] && { skip=1; break; }; done
    [[ "$skip" == "1" ]] && continue
    if git -C "$repo" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
      if git -C "$repo" branch -d "$branch" 2>/dev/null; then
        echo "  deleted branch: $branch (merged, no worktree)"
        deleted=$((deleted + 1))
      fi
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/)
  echo "  branches deleted: $deleted"
}

sweep_repo() {
  local repo="$1" do_fetch="$2"
  repo="$(cd "$repo" 2>/dev/null && pwd)" || { echo "Repo: $1"; echo "  error: not a directory"; return 1; }
  echo "Repo: $repo"

  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "  skip: not a git repository"; return 1
  fi

  if [[ "$do_fetch" == "1" ]]; then
    if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      git -C "$repo" fetch origin --prune >/dev/null 2>&1 || echo "  warn: fetch failed"
    else
      echo "  skip fetch: no origin remote"
    fi
  fi

  if ! git -C "$repo" rev-parse --verify origin/main >/dev/null 2>&1; then
    echo "  skip: no origin/main ref locally (fetch first)"
    return 0
  fi

  local primary_branch; primary_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  local kept_branches=("$primary_branch")
  local path branch
  while IFS=$'\t' read -r path branch; do
    [[ -n "$branch" ]] && kept_branches+=("$branch")
  done < <(list_worktrees "$repo")

  local rc=0
  sweep_worktrees "$repo" "$repo" "$primary_branch" || rc=1
  sweep_stale_branches "$repo" "${kept_branches[@]}"
  return "$rc"
}

sweep_main() {
  local do_fetch=0 repos=() arg
  for arg in "$@"; do
    case "$arg" in
      --fetch) do_fetch=1 ;;
      *) repos+=("$arg") ;;
    esac
  done

  if [[ ${#repos[@]} -eq 0 ]]; then
    local parent d
    parent="$(dirname "$REPO_ROOT")"
    while IFS= read -r -d '' d; do
      [[ -d "$d/.git" ]] && repos+=("$d")
    done < <(find "$parent" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
  fi

  echo "Sweeping ${#repos[@]} repo(s)..."
  local rc=0 r
  if [[ ${#repos[@]} -gt 0 ]]; then
    for r in "${repos[@]}"; do
      sweep_repo "$r" "$do_fetch" || rc=1
      echo ""
    done
  fi
  return "$rc"
}

# --- dispatch --------------------------------------------------------------

case "$ACTION" in
  list)
    echo "Active agent worktrees:"
    git -C "$REPO_ROOT" worktree list 2>/dev/null | grep "agent/" || echo "  (none)"
    ;;

  cleanup)
    echo "Cleaning up merged agent worktrees..."
    cleaned=0
    while IFS= read -r line; do
      path=$(echo "$line" | awk '{print $1}')
      branch=$(echo "$line" | awk '{print $3}' | tr -d '[]')
      [[ "$branch" != agent/* ]] && continue
      # Check if branch is merged into current
      if git -C "$REPO_ROOT" branch --merged 2>/dev/null | grep -q "${branch#*/}" 2>/dev/null; then
        echo "  Removing: $path ($branch)"
        git -C "$REPO_ROOT" worktree remove "$path" 2>/dev/null || true
        git -C "$REPO_ROOT" branch -d "$branch" 2>/dev/null || true
        cleaned=$((cleaned + 1))
      fi
    done < <(git -C "$REPO_ROOT" worktree list 2>/dev/null)
    echo "Cleaned $cleaned worktree(s)."
    ;;

  status)
    [[ -z "$AGENT" ]] && { echo "usage: $0 status <agent-name>" >&2; exit 2; }
    worktree=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep "$AGENT" | head -1 | awk '{print $1}')
    if [[ -z "$worktree" ]]; then
      echo "No active worktree for agent: $AGENT"
      exit 1
    fi
    echo "Agent: $AGENT"
    echo "Path: $worktree"
    echo "Last commit: $(git -C "$worktree" log --oneline -1 2>/dev/null || echo 'none')"
    echo "Uncommitted: $(git -C "$worktree" status --porcelain 2>/dev/null | wc -l | tr -d ' ') files"
    ;;

  sweep)
    shift
    sweep_main "$@"
    ;;

  *) echo "usage: $0 <list|cleanup|status|sweep> [args]" >&2; exit 2 ;;
esac
