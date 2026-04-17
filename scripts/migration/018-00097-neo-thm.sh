#!/usr/bin/env bash
# neovim: neo-tree highlights follow active omarchy colorscheme (link to Directory/Title)
set -euo pipefail

TRANSPARENCY="$HOME/.config/nvim/plugin/after/transparency.lua"

if [[ ! -f "$TRANSPARENCY" ]]; then
  echo "transparency.lua not found, skipping"
  exit 0
fi

if grep -q 'NeoTreeDirectoryIcon.*link = "Directory"' "$TRANSPARENCY"; then
  echo "neo-tree theme-follow highlights already present"
  exit 0
fi

echo "Converting neo-tree highlights to follow active colorscheme..."

# remove existing hardcoded hex-color neo-tree block (from 008-00033)
sed -i '/-- neotree folder icon colors/,/NeoTreeRootName/d' "$TRANSPARENCY"

# append link-based highlights so colors track the active colorscheme
cat >> "$TRANSPARENCY" << 'LUAEOF'

-- neo-tree highlights follow active colorscheme
vim.api.nvim_set_hl(0, "NeoTreeDirectoryIcon", { link = "Directory" })
vim.api.nvim_set_hl(0, "NeoTreeDirectoryName", { link = "Directory" })
vim.api.nvim_set_hl(0, "NeoTreeRootName",      { link = "Title" })
LUAEOF

echo "  transparency.lua: patched"
