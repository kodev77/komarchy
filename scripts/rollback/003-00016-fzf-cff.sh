#!/usr/bin/env bash
# fzf: rollback cdff function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko omarchy-setup cdff ---' "$BASHRC"; then
  echo "removing cdff function..."
  sed -i '/# --- BEGIN ko omarchy-setup cdff ---/,/# --- END ko omarchy-setup cdff ---/d' "$BASHRC"
  echo "cdff function removed"
else
  echo "cdff not found, skipping"
fi
