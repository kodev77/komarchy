#!/usr/bin/env bash
# dadbod: rollback blink.cmp integration: registers dadbod-completion as a source for sql filetypes
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/dadbod-blink.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "dadbod-blink.lua not found, skipping"
  exit 0
fi

echo "removing dadbod-blink plugin spec..."
rm "$PLUGIN"
echo "dadbod-blink.lua removed"
