#!/usr/bin/env bash
# fzf: rollback cdff function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy cdff ---' "$BASHRC"; then
  echo "removing cdff function..."
  sed -i '/# --- BEGIN ko komarchy cdff ---/,/# --- END ko komarchy cdff ---/d' "$BASHRC"
  echo "cdff function removed"
else
  echo "cdff not found, skipping"
fi
