#!/usr/bin/env bash
# neovim-gx: rollback markdown-aware gx keymap
set -euo pipefail

KEYMAPS="$HOME/.config/nvim/lua/config/keymaps.lua"

if [[ ! -f "$KEYMAPS" ]]; then
  echo "keymaps.lua not found, skipping"
  exit 0
fi

if ! grep -q 'Markdown-aware gx' "$KEYMAPS"; then
  echo "gx keymap not present, skipping"
  exit 0
fi

echo "Removing markdown-aware gx keymap..."

# Remove the gx block (blank line before comment through closing paren)
sed -i '/^$/N;/\n-- Markdown-aware gx/,/^end, { desc = "Open link under cursor (markdown-aware)" })$/d' "$KEYMAPS"
echo "  keymaps.lua: gx keymap removed"

echo ""
echo "restart nvim to apply changes"
