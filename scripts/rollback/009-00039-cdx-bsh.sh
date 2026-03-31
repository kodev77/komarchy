#!/usr/bin/env bash
# neovim-cdexit: rollback bash nvim cwd hook and cursor styling
set -euo pipefail

if ! grep -q '# --- BEGIN ko komarchy nvim-cdexit ---' "$HOME/.bashrc" 2>/dev/null; then
  echo "nvim cwd hook not found, skipping"
  exit 0
fi

echo "removing nvim cwd hook and cursor styling..."
sed -i '/# --- BEGIN ko komarchy nvim-cdexit ---/,/# --- END ko komarchy nvim-cdexit ---/d' "$HOME/.bashrc"
echo "nvim cwd hook removed"

echo ""
echo "open a new terminal to apply changes"
