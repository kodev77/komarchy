#!/usr/bin/env bash
# dadbod: rollback (NULL) detection patch
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if ! grep -q '(NULL)' "$FORMAT"; then
  echo "  not patched, skipping"
  exit 0
fi

echo "removing (NULL) detection patch..."

sed -i 's|if val == "NULL" or val == "(NULL)" or vim.trim(val) == "" then|if val == "NULL" or vim.trim(val) == "" then|' "$FORMAT"
sed -i 's|(val_text == "NULL" or val_text == "(NULL)") and "DboutNull"|val_text == "NULL" and "DboutNull"|' "$FORMAT"

echo "  util/dadbod-format.lua: (NULL) patch reverted"
