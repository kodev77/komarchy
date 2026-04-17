#!/usr/bin/env bash
# neovim: rollback neo-tree hue-based highlights (restore flat link block from 018-00097)
set -euo pipefail

NVIM_PLUGIN_AFTER="$HOME/.config/nvim/plugin/after"
TRANSPARENCY="$NVIM_PLUGIN_AFTER/transparency.lua"
HUE_FILE="$NVIM_PLUGIN_AFTER/neotree-hue.lua"

if [[ -f "$HUE_FILE" ]]; then
  rm -f "$HUE_FILE"
  echo "  removed $HUE_FILE"
else
  echo "  $HUE_FILE not present, skipping"
fi

if [[ -f "$TRANSPARENCY" ]] && ! grep -q 'NeoTreeDirectoryIcon.*link = "Directory"' "$TRANSPARENCY"; then
  cat >> "$TRANSPARENCY" << 'LUAEOF'

-- neo-tree highlights follow active colorscheme
vim.api.nvim_set_hl(0, "NeoTreeDirectoryIcon", { link = "Directory" })
vim.api.nvim_set_hl(0, "NeoTreeDirectoryName", { link = "Directory" })
vim.api.nvim_set_hl(0, "NeoTreeRootName",      { link = "Title" })
LUAEOF
  echo "  transparency.lua: restored flat link block"
fi
