#!/usr/bin/env bash
# dadbod: rollback data-row │ DboutBorder patch
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if ! grep -q -- "-- Data rows: " "$FORMAT"; then
  echo "  not patched, skipping"
  exit 0
fi

echo "removing data-row DboutBorder patch..."

sed -i '/^    -- Data rows: /,/^    end$/d' "$FORMAT"

echo "  util/dadbod-format.lua: data-row patch removed"
