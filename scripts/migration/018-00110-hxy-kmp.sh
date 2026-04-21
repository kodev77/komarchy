#!/usr/bin/env bash
# neovim: keymap <leader>ah to open current file in hexyl (terminal split)
set -euo pipefail

KEYMAPS="$HOME/.config/nvim/lua/config/keymaps.lua"

if [[ ! -f "$KEYMAPS" ]]; then
  echo "  keymaps.lua not found at $KEYMAPS, skipping"
  exit 2
fi

if grep -q 'komarchy: hexyl hex view' "$KEYMAPS"; then
  echo "  hexyl keymap already present, skipping"
  exit 0
fi

cat >> "$KEYMAPS" << 'KEYMAPSEOF'

-- komarchy: hexyl hex view of current file in a terminal split
vim.keymap.set("n", "<leader>ah", function()
  local file = vim.fn.expand("%:p")
  if file == "" or vim.fn.filereadable(file) == 0 then
    vim.notify("no readable file in current buffer", vim.log.levels.WARN)
    return
  end
  vim.cmd("terminal hexyl --panels 1 " .. vim.fn.shellescape(file))
end, { desc = "Hex view (hexyl)" })
-- komarchy: hexyl hex view end
KEYMAPSEOF
echo "  keymaps.lua: patched (<leader>ah -> hexyl)"

echo ""
echo "restart nvim to apply"
