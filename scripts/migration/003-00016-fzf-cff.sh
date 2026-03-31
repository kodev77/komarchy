#!/usr/bin/env bash
# fzf: bash function: cdff - fuzzy find a file and cd into its parent directory
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko omarchy-setup cdff ---' "$BASHRC"; then
  echo "cdff already configured, skipping"
  exit 0
fi

echo "adding cdff function to bashrc..."

cat >> "$BASHRC" << 'BASHRC'

# --- BEGIN ko omarchy-setup cdff ---

# Fuzzy find a file and cd into its parent directory
cdff() {
  local file dir
  file="$(fd --type f --hidden --exclude .git | fzf --layout=reverse --preview 'bat --color=always --style=numbers --line-range=:50 {}')" && dir="$(dirname "$file")" && builtin cd -- "$dir"
}

# --- END ko omarchy-setup cdff ---
BASHRC

echo "cdff function added"
