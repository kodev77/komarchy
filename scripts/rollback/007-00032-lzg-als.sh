#!/usr/bin/env bash
# lazygit: rollback bashrc: lazygit alias
set -euo pipefail

if ! grep -q '# --- BEGIN ko komarchy lazygit ---' "$HOME/.bashrc" 2>/dev/null; then
  echo "lg alias not found, skipping"
  exit 0
fi

echo "removing lg alias..."
sed -i '/# --- BEGIN ko komarchy lazygit ---/,/# --- END ko komarchy lazygit ---/d' "$HOME/.bashrc"
echo "lg alias removed"
