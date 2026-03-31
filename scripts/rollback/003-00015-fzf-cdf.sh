#!/usr/bin/env bash
# fzf: rollback cdf function
set -euo pipefail

BASHRC="$HOME/.bashrc"

if grep -q '# --- BEGIN ko komarchy cdf ---' "$BASHRC"; then
  echo "removing cdf function..."
  sed -i '/# --- BEGIN ko komarchy cdf ---/,/# --- END ko komarchy cdf ---/d' "$BASHRC"
  echo "cdf function removed"
else
  echo "cdf not found, skipping"
fi

echo ""
echo "start a new terminal to apply changes"
