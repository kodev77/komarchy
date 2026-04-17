#!/usr/bin/env bash
# dadbod: treat "(NULL)" the same as "NULL" so SQL Server results get the DboutNull italic style
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if grep -q '(NULL)' "$FORMAT"; then
  echo "  already patched, skipping"
  exit 0
fi

echo "patching NULL detection to also match (NULL)..."

# detect_column_type: skip "(NULL)" when tallying types
sed -i 's|if val == "NULL" or vim.trim(val) == "" then|if val == "NULL" or val == "(NULL)" or vim.trim(val) == "" then|' "$FORMAT"

# apply_highlighting: route "(NULL)" to DboutNull
sed -i 's|val_text == "NULL" and "DboutNull"|(val_text == "NULL" or val_text == "(NULL)") and "DboutNull"|' "$FORMAT"

echo "  util/dadbod-format.lua: (NULL) now treated as NULL"
