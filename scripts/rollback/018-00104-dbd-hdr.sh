#!/usr/bin/env bash
# dadbod: rollback header-row │ DboutBorder patch
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if ! grep -q "Header row . chrome" "$FORMAT"; then
  echo "  not patched, skipping"
  exit 0
fi

echo "removing header-row DboutBorder patch..."

sed -i '/^    -- Header row . chrome:/,/^    end$/d' "$FORMAT"

echo "  util/dadbod-format.lua: header-row patch removed"
