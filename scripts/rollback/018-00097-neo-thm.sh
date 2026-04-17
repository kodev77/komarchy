#!/usr/bin/env bash
# neovim: rollback neo-tree theme-follow highlights (restore hardcoded osaka-jade hex colors)
set -euo pipefail

TRANSPARENCY="$HOME/.config/nvim/plugin/after/transparency.lua"

if [[ ! -f "$TRANSPARENCY" ]]; then
  echo "transparency.lua not found, skipping"
  exit 0
fi

if ! grep -q 'NeoTreeDirectoryIcon.*link = "Directory"' "$TRANSPARENCY"; then
  echo "neo-tree theme-follow highlights not found, skipping"
  exit 0
fi

echo "restoring hardcoded neo-tree colors..."

# remove link-based neo-tree block
sed -i '/-- neo-tree highlights follow active colorscheme/,/NeoTreeRootName/d' "$TRANSPARENCY"

# restore hex block matching 008-00033 output
cat >> "$TRANSPARENCY" << 'LUAEOF'

-- neotree folder icon colors (match terminal theme)
vim.api.nvim_set_hl(0, "NeoTreeDirectoryIcon", { fg = "#509475" })
vim.api.nvim_set_hl(0, "NeoTreeDirectoryName", { fg = "#509475" })

-- neotree root name color (match terminal yellow)
vim.api.nvim_set_hl(0, "NeoTreeRootName", { fg = "#C1C497", bold = true })
LUAEOF

echo "  transparency.lua: reverted"
