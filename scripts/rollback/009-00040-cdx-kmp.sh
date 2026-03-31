#!/usr/bin/env bash
# neovim-cdexit: rollback neovim keymaps: quit-and-cd-shell (leader-qd) and quit-to-home (leader-qh)
set -euo pipefail

KEYMAPS="$HOME/.config/nvim/lua/config/keymaps.lua"

if [[ ! -f "$KEYMAPS" ]] || ! grep -q 'leader>qd' "$KEYMAPS"; then
  echo "cdexit keymaps not found, skipping"
  exit 0
fi

echo "removing cdexit keymaps..."
sed -i '/-- Quit and tell the shell to cd to nvim/,/{ desc = "Quit and cd shell to ~" })/d' "$KEYMAPS"
echo "cdexit keymaps removed"

echo ""
echo "open a new terminal and restart nvim to apply changes"
