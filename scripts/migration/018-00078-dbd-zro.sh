#!/usr/bin/env bash
# dadbod: normalize MySQL "Query OK" empty-result status to "(0 rows affected)" (match SQL Server)
set -euo pipefail

FMT="$HOME/.config/nvim/lua/util/dadbod-format.lua"

if [[ ! -f "$FMT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

changed=false

# Fallback 1: Query OK line without a numeric count
if grep -qE '^\s*current_status = line$' "$FMT"; then
  sed -i 's|current_status = line$|current_status = "(0 rows affected)"|' "$FMT"
  echo "  dadbod-format.lua: Query OK fallback patched"
  changed=true
fi

# Fallback 2: warnings-only output status
if grep -qF 'status = "Query OK"' "$FMT"; then
  sed -i 's|status = "Query OK"|status = "(0 rows affected)"|' "$FMT"
  echo "  dadbod-format.lua: warnings-only status patched"
  changed=true
fi

if ! $changed; then
  echo "  dadbod-format.lua: already patched"
  exit 0
fi

echo ""
echo "restart nvim to apply changes"
