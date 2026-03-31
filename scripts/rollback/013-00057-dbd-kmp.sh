#!/usr/bin/env bash
# dadbod: rollback dadbod keybindings: dbui toggle, run line/selection/file, connection select, format output
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/dadbod-keymaps.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "dadbod-keymaps.lua not found, skipping"
  exit 0
fi

echo "removing dadbod-keymaps plugin spec..."
rm "$PLUGIN"
echo "dadbod-keymaps.lua removed"
