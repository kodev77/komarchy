#!/usr/bin/env bash
# dadbod: rollback dadbod-completion plugin spec: sql autocomplete source for table and column names
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/dadbod-completion.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "dadbod-completion.lua not found, skipping"
  exit 0
fi

echo "removing dadbod-completion plugin spec..."
rm "$PLUGIN"
echo "dadbod-completion.lua removed"
