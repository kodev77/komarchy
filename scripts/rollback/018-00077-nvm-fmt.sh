#!/usr/bin/env bash
# neovim: rollback formatoptions autocmd and listchars override
set -euo pipefail

AUTOCMDS="$HOME/.config/nvim/lua/config/autocmds.lua"
OPTIONS="$HOME/.config/nvim/lua/config/options.lua"

echo "rolling back nvim config..."

# autocmds.lua: remove formatoptions autocmd
if [[ -f "$AUTOCMDS" ]] && grep -q 'disable auto-continuation of comments' "$AUTOCMDS"; then
  sed -i '/-- disable auto-continuation of comments/,/^})$/d' "$AUTOCMDS"
  echo "  formatoptions autocmd: removed"
else
  echo "  formatoptions autocmd: not found"
fi

# options.lua: remove listchars override
if [[ -f "$OPTIONS" ]] && grep -q 'listchars without trail' "$OPTIONS"; then
  sed -i '/-- listchars without trail/,/^vim\.opt\.listchars = { tab = "> ", nbsp = "+" }$/d' "$OPTIONS"
  echo "  listchars override: removed"
else
  echo "  listchars override: not found"
fi

echo ""
echo "restart nvim to apply changes"
