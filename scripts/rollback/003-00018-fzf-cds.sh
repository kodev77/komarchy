#!/usr/bin/env bash
# fzf: rollback cds function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy cds ---' "$BASHRC"; then
  echo "removing cds function..."
  sed -i '/# --- BEGIN ko komarchy cds ---/,/# --- END ko komarchy cds ---/d' "$BASHRC"
  echo "cds function removed"
else
  echo "cds not found, skipping"
fi
