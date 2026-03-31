#!/usr/bin/env bash
# neovim: neovim neo-tree folder icon and root name highlight colors
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"

echo "Patching neo-tree colors..."

TRANSPARENCY="$NVIM_DIR/plugin/after/transparency.lua"
if [[ -f "$TRANSPARENCY" ]] && ! grep -q 'NeoTreeDirectoryIcon' "$TRANSPARENCY"; then
  cat >> "$TRANSPARENCY" << 'LUAEOF'

-- neotree folder icon colors (match terminal theme)
vim.api.nvim_set_hl(0, "NeoTreeDirectoryIcon", { fg = "#509475" })
vim.api.nvim_set_hl(0, "NeoTreeDirectoryName", { fg = "#509475" })

-- neotree root name color (match terminal yellow)
vim.api.nvim_set_hl(0, "NeoTreeRootName", { fg = "#C1C497", bold = true })
LUAEOF
  echo "  transparency.lua: patched"
fi
