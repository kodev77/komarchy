#!/usr/bin/env bash
# fzf: rollback cds function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko omarchy-setup cds ---' "$BASHRC"; then
  echo "removing cds function..."
  sed -i '/# --- BEGIN ko omarchy-setup cds ---/,/# --- END ko omarchy-setup cds ---/d' "$BASHRC"
  echo "cds function removed"
else
  echo "cds not found, skipping"
fi
