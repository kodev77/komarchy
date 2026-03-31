#!/usr/bin/env bash
# fzf: bash function: cdf - fuzzy find a directory and cd into it
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko omarchy-setup cdf ---' "$BASHRC"; then
  echo "cdf already configured, skipping"
  exit 0
fi

echo "adding cdf function to bashrc..."

cat >> "$BASHRC" << 'BASHRC'

# --- BEGIN ko omarchy-setup cdf ---

# Fuzzy find a directory and cd into it
cdf() {
  local dir
  dir="$(fd --type d --hidden --exclude .git | fzf --layout=reverse --preview 'eza -la --color=always --icons {}')" && builtin cd -- "$dir"
}

# --- END ko omarchy-setup cdf ---
BASHRC

echo "cdf function added"
