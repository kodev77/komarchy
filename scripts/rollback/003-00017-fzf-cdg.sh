#!/usr/bin/env bash
# fzf: rollback cdg function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko omarchy-setup cdg ---' "$BASHRC"; then
  echo "removing cdg function..."
  sed -i '/# --- BEGIN ko omarchy-setup cdg ---/,/# --- END ko omarchy-setup cdg ---/d' "$BASHRC"
  echo "cdg function removed"
else
  echo "cdg not found, skipping"
fi
