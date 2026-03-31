#!/usr/bin/env bash
# hello: remove ko komarchy git config additions
set -euo pipefail

CONFIG="$HOME/.config/git/config"

if [[ ! -f "$CONFIG" ]]; then
  echo "git config not found, skipping"
  exit 0
fi

if grep -q "# --- BEGIN ko komarchy ---" "$CONFIG"; then
  echo "removing git config customizations..."
  sed -i '/# --- BEGIN ko komarchy ---/,/# --- END ko komarchy ---/d' "$CONFIG"
  echo "git config removed"
else
  echo "git config customizations not found, skipping"
fi
