#!/usr/bin/env bash
# dev-symlink-doctor.sh — Verify (and optionally repair) the "edition live"
# symlink montage between plugin cache installs and their dev repos.
#
# Usage:
#   tools/dev-symlink-doctor.sh [--repair]
#
# Map file (default ~/.claude/dev-symlink.map, override via DEV_SYMLINK_MAP):
#   <cache_install_dir>|<dev_repo_dir>|<mode>
#   mode = "tree" (every mounted top-level cache entry must be a symlink
#          into the dev repo — see mounted_entries() for how "mounted" is
#          detected) or a relative path (binary mode: that one path must be
#          a symlink into the dev repo, e.g.
#          target/release/automatised-pipeline).
#   Blank lines and lines starting with # are ignored. ~ expands to $HOME.
#
# Repair pattern (per broken entry, idempotent):
#   - if <entry>.orig-backup already exists: rm -rf <entry>
#   - else: mv <entry> <entry>.orig-backup
#   - ln -s <dev_repo_dir>/<entry> <entry>
#   Never touches .claude-plugin, .git*, or .in_use.
#
# Exit codes: 0 all OK (or no map file), 1 at least one BROKEN entry, 2 usage.

set -euo pipefail

MODE="check"
case "${1:-}" in
  --repair) MODE="repair" ;;
  "") ;;
  *) echo "usage: $0 [--repair]" >&2; exit 2 ;;
esac

MAP_FILE="${DEV_SYMLINK_MAP:-$HOME/.claude/dev-symlink.map}"

expand_tilde() {
  local p="$1"
  case "$p" in
    "~"*) printf '%s' "$HOME${p#\~}" ;;
    *) printf '%s' "$p" ;;
  esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_excluded_entry() {
  case "$1" in
    .claude-plugin|.in_use|.DS_Store) return 0 ;;
    .git*) return 0 ;;
    *.orig-backup) return 0 ;;
    *) return 1 ;;
  esac
}

# A cache entry is part of the live montage iff it has an <entry>.orig-backup
# sibling (the artifact left by the mount pattern's `mv X X.orig-backup`
# step) — NOT merely "same name exists in the dev repo too": plenty of
# top-level files (.mcp.json, generated per-install manifests, etc.) share a
# name with the dev repo but were never intended to be symlinked. The backup
# file is the only reliable signal of intent.
mounted_entries() {
  local cache="$1" entry name
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    case "$name" in
      *.orig-backup) printf '%s\n' "${name%.orig-backup}" ;;
    esac
  done < <(find "$cache" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
}

# Prints "<name>\t<reason>" for each broken mounted entry (tree mode).
check_tree() {
  local cache="$1" dev="$2" dev_abs name entry expected actual
  dev_abs="$(cd "$dev" 2>/dev/null && pwd)" || { printf '%s\t%s\n' "(dev repo)" "missing ($dev)"; return; }
  while IFS= read -r name; do
    is_excluded_entry "$name" && continue
    entry="$cache/$name"
    expected="$dev_abs/$name"
    if [[ -L "$entry" ]]; then
      actual="$(readlink "$entry")"
      [[ "$actual" == "$expected" ]] || printf '%s\t%s\n' "$name" "points elsewhere ($actual)"
    elif [[ -e "$entry" ]]; then
      printf '%s\t%s\n' "$name" "not a symlink (backup present, live mount missing)"
    else
      printf '%s\t%s\n' "$name" "missing (backup present, no live mount)"
    fi
  done < <(mounted_entries "$cache")
}

# Prints "<rel>\t<reason>" if the single binary-mode path is broken.
check_binary() {
  local cache="$1" dev="$2" rel="$3" dev_abs entry expected actual
  dev_abs="$(cd "$dev" 2>/dev/null && pwd)" || { printf '%s\t%s\n' "$rel" "dev repo missing"; return; }
  entry="$cache/$rel"
  expected="$dev_abs/$rel"
  if [[ ! -e "$entry" && ! -L "$entry" ]]; then
    printf '%s\t%s\n' "$rel" "missing"
  elif [[ -L "$entry" ]]; then
    actual="$(readlink "$entry")"
    [[ "$actual" == "$expected" ]] || printf '%s\t%s\n' "$rel" "points elsewhere ($actual)"
  else
    printf '%s\t%s\n' "$rel" "not a symlink"
  fi
}

# Repairs one broken entry (tree entry name, or binary-mode relative path).
repair_entry() {
  local cache="$1" dev="$2" rel="$3" entry target
  entry="$cache/$rel"
  target="$dev/$rel"
  if [[ -e "${entry}.orig-backup" || -L "${entry}.orig-backup" ]]; then
    rm -rf "$entry"
  elif [[ -e "$entry" || -L "$entry" ]]; then
    mkdir -p "$(dirname "$entry")"
    mv "$entry" "${entry}.orig-backup"
  fi
  mkdir -p "$(dirname "$entry")"
  ln -s "$target" "$entry"
  echo "    repaired: $rel"
}

process_mapping() {
  local cache="$1" dev="$2" mode="$3" label broken_line name reason had_broken=0

  cache="$(expand_tilde "$cache")"; dev="$(expand_tilde "$dev")"
  label="$(basename "$(dirname "$cache")")/$(basename "$cache")"

  if [[ ! -d "$cache" ]]; then
    echo "  BROKEN $label: cache install dir missing ($cache)"
    return 1
  fi

  local broken=()
  if [[ "$mode" == "tree" ]]; then
    while IFS=$'\t' read -r name reason; do
      [[ -z "$name" ]] && continue
      broken+=("$name|$reason")
    done < <(check_tree "$cache" "$dev")
  else
    while IFS=$'\t' read -r name reason; do
      [[ -z "$name" ]] && continue
      broken+=("$name|$reason")
    done < <(check_binary "$cache" "$dev" "$mode")
  fi

  if [[ ${#broken[@]} -eq 0 ]]; then
    echo "  OK      $label"
    return 0
  fi

  had_broken=1
  for broken_line in "${broken[@]}"; do
    name="${broken_line%%|*}"; reason="${broken_line#*|}"
    echo "  BROKEN  $label: $name ($reason)"
    if [[ "$MODE" == "repair" ]]; then
      repair_entry "$cache" "$dev" "$name"
    fi
  done
  return "$had_broken"
}

main() {
  if [[ ! -f "$MAP_FILE" ]]; then
    echo "dev-symlink-doctor: no map file at $MAP_FILE — nothing to check"
    exit 0
  fi

  local rc=0 cache dev mode
  while IFS='|' read -r cache dev mode || [[ -n "$cache" ]]; do
    cache="$(trim "$cache")"
    [[ -z "$cache" || "$cache" == \#* ]] && continue
    dev="$(trim "${dev:-}")"
    mode="$(trim "${mode:-}")"
    [[ -z "$dev" || -z "$mode" ]] && { echo "  skip malformed line: $cache|$dev|$mode" >&2; continue; }
    process_mapping "$cache" "$dev" "$mode" || rc=1
  done < "$MAP_FILE"

  exit "$rc"
}

main
