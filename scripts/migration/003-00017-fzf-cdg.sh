#!/usr/bin/env bash
# fzf: bash function: cdg - grep/rg (ripgrep) file contents and cd into matched file's parent
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy cdg ---' "$BASHRC"; then
  echo "cdg already configured, skipping"
  exit 0
fi

echo "adding cdg function to bashrc..."

cat >> "$BASHRC" << 'BASHRC'

# --- BEGIN ko komarchy cdg ---

# Search file contents and cd into the matched file's parent directory
cdg() {
  local match file dir
  match="$(rg --color=always --line-number --no-heading . | fzf --layout=reverse --ansi --preview 'bat --color=always --style=numbers --highlight-line {2} {1}' --delimiter : --preview-window '+{2}-5')" && file="$(echo "$match" | cut -d: -f1)" && dir="$(dirname "$file")" && builtin cd -- "$dir"
}

# --- END ko komarchy cdg ---
BASHRC

echo "cdg function added"
