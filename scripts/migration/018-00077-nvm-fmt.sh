#!/usr/bin/env bash
# neovim: disable auto-continuation of comments/lists and drop trailing-space dash
set -euo pipefail

AUTOCMDS="$HOME/.config/nvim/lua/config/autocmds.lua"
OPTIONS="$HOME/.config/nvim/lua/config/options.lua"

echo "Patching nvim config..."

# autocmds.lua: disable comment/list auto-continuation
if [[ ! -f "$AUTOCMDS" ]]; then
  echo "  autocmds.lua not found, skipping formatoptions patch"
elif grep -q 'disable auto-continuation of comments' "$AUTOCMDS"; then
  echo "  formatoptions autocmd: already patched"
else
  cat >> "$AUTOCMDS" << 'LUAEOF'

-- disable auto-continuation of comments and lists in all filetypes
-- uses BufEnter to run after runtime ftplugins (e.g. sql.vim, markdown.vim)
-- which would otherwise re-set formatoptions for their filetype
vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
  pattern = "*",
  callback = function()
    vim.opt_local.formatoptions:remove({ "r", "o", "c" })
  end,
})
LUAEOF
  echo "  formatoptions autocmd: patched"
fi

# options.lua: remove trail from listchars so trailing spaces stay as spaces
if [[ ! -f "$OPTIONS" ]]; then
  echo "  options.lua not found, skipping listchars patch"
elif grep -q 'listchars without trail' "$OPTIONS"; then
  echo "  listchars override: already patched"
else
  cat >> "$OPTIONS" << 'LUAEOF'

-- listchars without trail: don't render trailing spaces as dashes
vim.opt.listchars = { tab = "> ", nbsp = "+" }
LUAEOF
  echo "  listchars override: patched"
fi

echo ""
echo "restart nvim to apply changes"
