#!/usr/bin/env bash
# dadbod: rollback neovim dadbod-format utility module (used by dadbod plugins)
set -euo pipefail

FILE="$HOME/.config/nvim/lua/util/dadbod-format.lua"

if [[ ! -f "$FILE" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

echo "removing dadbod-format util..."
rm "$FILE"
echo "dadbod-format.lua removed"

echo ""
echo "cleaning removed neovim plugins..."
nvim --headless -c "lua require('lazy').clean({wait=true})" -c "sleep 3" -c "qa" 2>&1 || true

echo "  dadbod cleanup: OK"

echo ""
echo "restart nvim to apply changes"
