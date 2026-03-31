#!/usr/bin/env bash
# fzf: bash function: cds - unified fuzzy search across dirs, files, and contents
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy cds ---' "$BASHRC"; then
  echo "cds already configured, skipping"
  exit 0
fi

echo "adding cds function to bashrc..."

cat >> "$BASHRC" << 'BASHRC'

# --- BEGIN ko komarchy cds ---

# Unified fuzzy search: dirs, filenames, file contents — cd into result
__cds_search() {
  local q="$1"
  [ -z "$q" ] && return
  fd --type d --hidden --exclude .git | grep -i --color=always "$q" | sed $'s/^/dir\t/'
  fd --type f --hidden --exclude .git | grep -i --color=always "$q" | sed $'s/^/file\t/'
  rg --line-number --no-heading --color=always --hidden --glob '!.git' "$q" 2>/dev/null | sed $'s/^/grep\t/'
}
export -f __cds_search

# Live fuzzy search across dirs, files, and contents — cd into the result
cds() {
  local sel type path dir q="${*}"
  sel=$(
    __cds_search "$q" | fzf --layout=reverse --disabled --no-sort --ansi --delimiter=$'\t' \
      --prompt 'search> ' \
      --query "$q" \
      --header 'Type to search dirs, files, and contents' \
      --bind 'change:reload:__cds_search {q} || true' \
      --preview '
        type={1}; rest={2..}
        if [ "$type" = "dir" ]; then
          eza -la --color=always --icons "$rest"
        elif [ "$type" = "file" ]; then
          bat --color=always --style=numbers --line-range=:50 "$rest"
        elif [ "$type" = "grep" ]; then
          file=$(echo "$rest" | cut -d: -f1)
          lineno=$(echo "$rest" | cut -d: -f2)
          bat --color=always --style=numbers --highlight-line "$lineno" "$file"
        fi
      '
  )
  [ -z "$sel" ] && return

  type=$(echo "$sel" | cut -f1)
  path=$(echo "$sel" | cut -f2-)

  case "$type" in
    dir)  dir="$path" ;;
    file) dir="$(dirname "$path")" ;;
    grep) dir="$(dirname "$(echo "$path" | cut -d: -f1)")" ;;
  esac

  builtin cd -- "$dir"
}

# --- END ko komarchy cds ---
BASHRC

echo "cds function added"

echo ""
echo "reload bashrc to apply changes:"
echo "source ~/.bashrc"
