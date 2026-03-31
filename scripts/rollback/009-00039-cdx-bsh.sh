#!/usr/bin/env bash
# neovim-cdexit: rollback bash nvim cwd hook and cursor styling
set -euo pipefail

if ! grep -q '# --- BEGIN ko omarchy-setup nvim-cdexit ---' "$HOME/.bashrc" 2>/dev/null; then
  echo "nvim cwd hook not found, skipping"
  exit 0
fi

echo "removing nvim cwd hook and cursor styling..."
sed -i '/# --- BEGIN ko omarchy-setup nvim-cdexit ---/,/# --- END ko omarchy-setup nvim-cdexit ---/d' "$HOME/.bashrc"
echo "nvim cwd hook removed"

echo ""
echo "open a new terminal to apply changes"
