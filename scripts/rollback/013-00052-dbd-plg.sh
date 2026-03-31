#!/usr/bin/env bash
# dadbod: rollback vim-dadbod plugin spec: core database interface layer, lazy-loaded by dadbod-ui
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/dadbod.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "dadbod.lua not found, skipping"
  exit 0
fi

echo "removing dadbod plugin spec..."
rm "$PLUGIN"
echo "dadbod.lua removed"
