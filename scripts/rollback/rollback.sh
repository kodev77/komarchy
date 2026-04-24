#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_DIR/scripts/migration"
export REPO_DIR MIGRATIONS_DIR

STATE_DIR="$HOME/.local/state/kodev77/komarchy/migrations"

declare -A GROUP_NAMES=(
  [000]="hello" [001]="hyprland" [002]="waybar" [003]="fzf"
  [004]="terminal" [005]="berkeley" [006]="libre" [007]="lazygit"
  [008]="neovim" [009]="neovim-cdexit" [010]="typescript" [011]="azure"
  [012]="dotnet" [013]="dadbod" [014]="sqlserver" [015]="mysql"
  [016]="dataverse" [017]="db2" [018]="updates" [019]="bm-tool"
  [020]="bm-tool" [021]="updates"
)
GROUP_ORDER=(000 001 002 003 004 005 006 007 008 009 010 011 012 013 014 015 016 017 018 019 020 021)

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

# --- build script index (once) ---
declare -A GROUP_SCRIPTS  # group -> newline-separated list of filenames

for script in "$REPO_DIR"/scripts/rollback/[0-9]*.sh; do
  [ -f "$script" ] || continue
  local_name="$(basename "$script")"
  group="${local_name:0:3}"
  GROUP_SCRIPTS[$group]+="$local_name"$'\n'
done

has_scripts=false
for group in "${GROUP_ORDER[@]}"; do
  [[ -n "${GROUP_SCRIPTS[$group]+x}" ]] && { has_scripts=true; break; }
done
if ! $has_scripts; then
  blue "nothing to roll back."
  exit 0
fi

# --- state helpers ---
is_migrated() {
  [[ -f "$STATE_DIR/$1" ]]
}

unmark_migrated() {
  rm -f "$STATE_DIR/$1"
}

is_group_migrated() {
  local group="$1" name
  [[ -n "${GROUP_SCRIPTS[$group]+x}" ]] || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    is_migrated "$name" && return 0
  done <<< "${GROUP_SCRIPTS[$group]}"
  return 1
}

rollback_group() {
  local group="$1"
  local group_display="${group}-${GROUP_NAMES[$group]}"
  local any_rolled_back=false
  local header_shown=false

  # collect into array for reverse iteration
  local scripts=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    scripts+=("$name")
  done <<< "${GROUP_SCRIPTS[$group]}"

  for (( i=${#scripts[@]}-1; i>=0; i-- )); do
    local name="${scripts[$i]}"

    if ! is_migrated "$name"; then
      continue
    fi

    if ! $header_shown; then
      green "rollback $group_display"
      header_shown=true
    fi

    any_rolled_back=true
    echo "$name"
    echo ""
    if ! bash "$REPO_DIR/scripts/rollback/$name"; then
      echo ""
      red "fail $name"
      echo ""
      read -rp "continue with remaining rollbacks? [y/N] " answer
      echo ""
      if [[ "${answer,,}" != "y" ]]; then
        red "aborted."
        exit 1
      fi
      continue
    fi

    unmark_migrated "$name"
  done

  if ! $any_rolled_back; then
    blue "skip $group_display (not migrated)"
    return 1
  fi
}

# reverse group order for rollback
reversed=()
for (( i=${#GROUP_ORDER[@]}-1; i>=0; i-- )); do
  reversed+=("${GROUP_ORDER[$i]}")
done

# build fzf list
items=()
items+=("[Rollback All]")
for group in "${reversed[@]}"; do
  group_display="${group}-${GROUP_NAMES[$group]}"
  if is_group_migrated "$group"; then
    items+=("<$group_display>")
  else
    items+=("<$group_display> \033[0;34m(not migrated)\033[0m")
  fi
  # list scripts in reverse
  [[ -n "${GROUP_SCRIPTS[$group]+x}" ]] || continue
  scripts=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    scripts+=("$name")
  done <<< "${GROUP_SCRIPTS[$group]}"
  for (( i=${#scripts[@]}-1; i>=0; i-- )); do
    name="${scripts[$i]}"
    if is_migrated "$name"; then
      items+=("  $name")
    else
      items+=("  $name \033[0;34m(not migrated)\033[0m")
    fi
  done
done

selection=$(printf '%b\n' "${items[@]}" | fzf --ansi --prompt="rollback > " --height=100% --reverse --no-info) || exit 2

# strip ansi codes and status suffix
selection=$(echo "$selection" | sed 's/\x1b\[[0-9;]*m//g')
selection="${selection% (not migrated)}"
selection="${selection#<}"; selection="${selection%>}"
# strip leading whitespace
selection="${selection#"${selection%%[![:space:]]*}"}"

if [[ "$selection" == "[Rollback All]" ]]; then
  any_pending=false
  for group in "${reversed[@]}"; do
    is_group_migrated "$group" && { any_pending=true; break; }
  done
  if $any_pending; then
    if ! sudo -n true 2>/dev/null; then
      sudo -v
    fi
  fi
  any_rolled_back=false
  for group in "${reversed[@]}"; do
    rollback_group "$group" && any_rolled_back=true
  done
  green "rollback complete"
  if $any_rolled_back; then
    echo ""
    read -rp "reboot now to apply changes? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      systemctl reboot
    else
      blue "reboot to apply changes"
    fi
  fi
elif [[ "$selection" == *.sh ]]; then
  # single script rollback
  if [[ ! -f "$REPO_DIR/scripts/rollback/$selection" ]]; then
    red "rollback script not found: $selection"
    exit 1
  fi

  if ! is_migrated "$selection"; then
    blue "skip $selection (not migrated)"
  else
    echo "$selection"
    echo ""
    if bash "$REPO_DIR/scripts/rollback/$selection"; then
      unmark_migrated "$selection"
      echo ""
      green "rollback complete"
    else
      echo ""
      red "fail $selection"
      exit 1
    fi
  fi
else
  # group selected
  local_group="${selection%%-*}"
  if [[ -n "${GROUP_NAMES[$local_group]+x}" ]]; then
    rollback_group "$local_group"
    green "rollback complete"
  fi
fi
