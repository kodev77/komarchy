#!/usr/bin/env bash
# dadbod: rollback lua utilities for query execution, visual selection, connection picker, and popup clipboard
set -euo pipefail

FILE="$HOME/.config/nvim/lua/util/dadbod-helpers.lua"

if [[ ! -f "$FILE" ]]; then
  echo "dadbod-helpers.lua not found, skipping"
  exit 0
fi

echo "removing dadbod-helpers util..."
rm "$FILE"
echo "dadbod-helpers.lua removed"
