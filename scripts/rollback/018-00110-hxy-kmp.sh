#!/usr/bin/env bash
# neovim: rollback <leader>ah hexyl hex view keymap
set -euo pipefail

KEYMAPS="$HOME/.config/nvim/lua/config/keymaps.lua"

if [[ ! -f "$KEYMAPS" ]] || ! grep -q 'komarchy: hexyl hex view' "$KEYMAPS"; then
  echo "hexyl keymap not found, skipping"
  exit 0
fi

echo "removing hexyl keymap..."
sed -i '/-- komarchy: hexyl hex view of current file/,/-- komarchy: hexyl hex view end/d' "$KEYMAPS"
echo "hexyl keymap removed"

echo ""
echo "restart nvim to apply"
