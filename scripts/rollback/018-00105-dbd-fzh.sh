#!/usr/bin/env bash
# dadbod: rollback frozen-header │ DboutBorder patch
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if ! grep -q "Overlay DboutBorder on each" "$FORMAT"; then
  echo "  not patched, skipping"
  exit 0
fi

echo "removing frozen-header DboutBorder patch..."

sed -i '/^      -- Overlay DboutBorder on each/,/^      end$/d' "$FORMAT"

echo "  util/dadbod-format.lua: frozen-header patch removed"
