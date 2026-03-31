#!/usr/bin/env bash
# neovim: rollback neovim diffview plugin with git diff keybindings
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/diffview.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "diffview plugin not found, skipping"
  exit 0
fi

echo "removing diffview plugin spec..."
rm "$PLUGIN"
echo "diffview plugin removed"
