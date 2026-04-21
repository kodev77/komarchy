#!/usr/bin/env bash
# neovim: 6502 assembly syntax highlighting for ACME assembler
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/acme-6502.lua"

if [[ -f "$PLUGIN" ]] && grep -q 'leissa/vim-acme' "$PLUGIN" && grep -q 'asm = "acme"' "$PLUGIN" && grep -q 'ASM = "acme"' "$PLUGIN"; then
  echo "  acme-6502.lua already installed, skipping"
  exit 0
fi

cat > "$PLUGIN" << 'LUAEOF'
-- komarchy: 6502 assembly (ACME) syntax highlighting
return {
  {
    "leissa/vim-acme",
    ft = "acme",
    init = function()
      vim.filetype.add({
        extension = {
          asm = "acme",
          ASM = "acme",
        },
      })
    end,
  },
}
LUAEOF
echo "  wrote $PLUGIN"
