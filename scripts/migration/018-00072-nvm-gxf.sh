#!/usr/bin/env bash
# neovim-gx: markdown-aware gx keymap — open markdown link URL from anywhere on the line
set -euo pipefail

KEYMAPS="$HOME/.config/nvim/lua/config/keymaps.lua"

if [[ ! -f "$KEYMAPS" ]]; then
  echo "keymaps.lua not found, skipping"
  exit 0
fi

if grep -q 'Markdown-aware gx' "$KEYMAPS"; then
  echo "gx keymap already present, skipping"
  exit 0
fi

echo "Patching nvim keymaps with markdown-aware gx..."

cat >> "$KEYMAPS" << 'KEYMAPSEOF'

-- Markdown-aware gx: open markdown link URL from anywhere on the line
vim.keymap.set("n", "gx", function()
  local line = vim.api.nvim_get_current_line()
  local _, url = line:match("%[(.-)%]%((.-)%)")
  if url then
    vim.ui.open(url)
  else
    vim.ui.open(vim.fn.expand("<cfile>"))
  end
end, { desc = "Open link under cursor (markdown-aware)" })
KEYMAPSEOF
echo "  keymaps.lua: patched"

echo ""
echo "restart nvim to apply changes"
