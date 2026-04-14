#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATIONS_DIR="$REPO_DIR/scripts/migration"
export REPO_DIR MIGRATIONS_DIR

STATE_DIR="$HOME/.local/state/kodev77/komarchy/migrations"
mkdir -p "$STATE_DIR"

declare -A GROUP_NAMES=(
  [000]="hello" [001]="hyprland" [002]="waybar" [003]="fzf"
  [004]="terminal" [005]="berkeley" [006]="libre" [007]="lazygit"
  [008]="neovim" [009]="neovim-cdexit" [010]="typescript" [011]="azure"
  [012]="dotnet" [013]="dadbod" [014]="sqlserver" [015]="mysql"
  [016]="dataverse" [017]="db2" [018]="updates"
)
GROUP_ORDER=(000 001 002 003 004 005 006 007 008 009 010 011 012 013 014 015 016 017 018)

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

# --- state file migration (one-time) ---
migrate_old_state() {
  local found=false
  for f in "$STATE_DIR"/*__*; do
    [ -f "$f" ] || continue
    found=true
    break
  done
  $found || return 0

  echo "migrating state files to new format..."
  for f in "$STATE_DIR"/*__*; do
    [ -f "$f" ] || continue
    local old_name
    old_name="$(basename "$f")"
    local group="${old_name%%-*}"
    local after_sep="${old_name#*__}"
    local seq="${after_sep%%-*}"
    local match
    match=$(ls "$MIGRATIONS_DIR"/${group}-${seq}-*.sh 2>/dev/null | head -1)
    if [[ -n "$match" ]]; then
      local new_name
      new_name="$(basename "$match")"
      local gname="${GROUP_NAMES[$group]}"
      local desc
      desc=$(sed -n '2s/^# *//p' "$match")
      echo "${gname}: ${desc}" > "$STATE_DIR/$new_name"
      rm -f "$f"
    else
      mv "$f" "$STATE_DIR/${group}-${seq}.sh"
    fi
  done
  echo "state migration complete"
}
migrate_old_state

# --- build script index (once) ---
declare -A GROUP_SCRIPTS  # group -> newline-separated list of filenames
ALL_SCRIPTS=()

for script in "$MIGRATIONS_DIR"/[0-9]*.sh; do
  [ -f "$script" ] || continue
  local_name="$(basename "$script")"
  ALL_SCRIPTS+=("$local_name")
  group="${local_name:0:3}"
  GROUP_SCRIPTS[$group]+="$local_name"$'\n'
done

if [[ ${#ALL_SCRIPTS[@]} -eq 0 ]]; then
  blue "no migration scripts found."
  exit 0
fi

# --- state helpers ---
is_migrated() {
  [[ -f "$STATE_DIR/$1" ]]
}

mark_migrated() {
  local name="$1"
  local group="${name:0:3}"
  local gname="${GROUP_NAMES[$group]}"
  local desc
  desc=$(sed -n '2s/^# *//p' "$MIGRATIONS_DIR/$name")
  echo "${gname}: ${desc}" > "$STATE_DIR/$name"
}

is_group_done() {
  local group="$1"
  local script
  while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    is_migrated "$script" || return 1
  done <<< "${GROUP_SCRIPTS[$group]}"
  return 0
}

run_group() {
  local group="$1"
  local group_display="${group}-${GROUP_NAMES[$group]}"
  local all_done=true
  local header_shown=false
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue

    if is_migrated "$name"; then
      continue
    fi

    if ! $header_shown; then
      green "run $group_display"
      header_shown=true
    fi

    all_done=false
    echo "$name"
    echo ""
    local rc=0
    bash "$MIGRATIONS_DIR/$name" || rc=$?
    if [[ $rc -eq 2 ]]; then
      continue
    elif [[ $rc -ne 0 ]]; then
      echo ""
      red "fail $name"
      echo ""
      read -rp "continue with remaining scripts? [y/N] " answer
      echo ""
      if [[ "${answer,,}" != "y" ]]; then
        red "aborted."
        exit 1
      fi
      continue
    fi

    mark_migrated "$name"
  done <<< "${GROUP_SCRIPTS[$group]}"

  if $all_done; then
    blue "skip $group_display (already migrated)"
    return 1
  fi
}

did_work=false

while true; do

# build fzf list
items=()
items+=("[Migrate All]")
items+=("[Rollback...]")
for group in "${GROUP_ORDER[@]}"; do
  group_display="${group}-${GROUP_NAMES[$group]}"
  if is_group_done "$group"; then
    items+=("<$group_display> \033[0;32m(done)\033[0m")
  else
    items+=("<$group_display> \033[0;34m(not migrated)\033[0m")
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if is_migrated "$name"; then
      items+=("  $name \033[0;32m(done)\033[0m")
    else
      items+=("  $name \033[0;34m(not migrated)\033[0m")
    fi
  done <<< "${GROUP_SCRIPTS[$group]}"
done

selection=$(printf '%b\n' "${items[@]}" | fzf --ansi --prompt="migrate > " --height=100% --reverse --no-info) || {
  if ! $did_work; then
    blue "cancelled."
  fi
  exit 0
}

# strip ansi codes and status suffix
selection=$(echo "$selection" | sed 's/\x1b\[[0-9;]*m//g')
selection="${selection% (done)}"
selection="${selection% (not migrated)}"
selection="${selection#<}"; selection="${selection%>}"
# strip leading whitespace
selection="${selection#"${selection%%[![:space:]]*}"}"

if [[ "$selection" == "[Rollback...]" ]]; then
  rc=0
  bash "$REPO_DIR/scripts/rollback/rollback.sh" || rc=$?
  if [[ $rc -eq 2 ]]; then
    continue
  fi
  did_work=true
  break
elif [[ "$selection" == "[Migrate All]" ]]; then
  # prompt for sudo upfront so scripts don't pause mid-run
  any_pending=false
  for group in "${GROUP_ORDER[@]}"; do
    is_group_done "$group" || { any_pending=true; break; }
  done
  if $any_pending; then
    if ! sudo -n true 2>/dev/null; then
      sudo -v
    fi
  fi
  any_migrated=false
  for group in "${GROUP_ORDER[@]}"; do
    run_group "$group" && any_migrated=true
  done
  green "migrate complete"
  if $any_migrated; then
    echo ""
    read -rp "reboot now to apply changes? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      systemctl reboot
    else
      blue "reboot to apply changes"
    fi
  fi
elif [[ "$selection" == *.sh ]]; then
  # single script
  if is_migrated "$selection"; then
    blue "skip $selection (already migrated)"
  else
    echo "$selection"
    echo ""
    rc=0
    bash "$MIGRATIONS_DIR/$selection" || rc=$?
    if [[ $rc -eq 2 ]]; then
      blue "skip $selection (dependency not available)"
    elif [[ $rc -eq 0 ]]; then
      mark_migrated "$selection"
      echo ""
      green "migrate complete"
    else
      echo ""
      red "fail $selection"
      exit 1
    fi
  fi
else
  # group selected — extract group key (first 3 chars)
  local_group="${selection%%-*}"
  if [[ -n "${GROUP_NAMES[$local_group]+x}" ]]; then
    run_group "$local_group"
    green "migrate complete"
  fi
fi

break
done
