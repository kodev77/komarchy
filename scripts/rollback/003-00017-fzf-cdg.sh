#!/usr/bin/env bash
# fzf: rollback cdg function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy cdg ---' "$BASHRC"; then
  echo "removing cdg function..."
  sed -i '/# --- BEGIN ko komarchy cdg ---/,/# --- END ko komarchy cdg ---/d' "$BASHRC"
  echo "cdg function removed"
else
  echo "cdg not found, skipping"
fi
