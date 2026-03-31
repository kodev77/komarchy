#!/usr/bin/env bash
# neovim: rollback neovim neo-tree folder icon and root name highlight colors
set -euo pipefail

TRANSPARENCY="$HOME/.config/nvim/plugin/after/transparency.lua"

if [[ ! -f "$TRANSPARENCY" ]] || ! grep -q 'NeoTreeDirectoryIcon' "$TRANSPARENCY"; then
  echo "neo-tree colors not found, skipping"
  exit 0
fi

echo "removing neo-tree color overrides..."
sed -i '/-- neotree folder icon colors/,/NeoTreeRootName/d' "$TRANSPARENCY"
echo "neo-tree colors removed"

echo ""
echo "cleaning removed neovim plugins..."
nvim --headless -c "lua require('lazy').clean({wait=true})" -c "sleep 3" -c "qa" 2>&1 || true

echo "updating treesitter parsers..."
nvim --headless -c "TSUpdate" -c "sleep 5" -c "qa" 2>&1 || true

echo "  neovim cleanup: OK"

echo ""
echo "restart nvim to apply changes"
