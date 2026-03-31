#!/usr/bin/env bash
# db2: rollback neovim db2 custom password manager plugin spec
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/db2.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "db2 plugin not found, skipping"
  exit 0
fi

echo "removing db2 plugin spec..."
rm "$PLUGIN"
echo "db2 plugin removed"

echo ""
echo "restart nvim to apply changes"
