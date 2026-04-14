#!/usr/bin/env bash
# dadbod: rollback MySQL zero-rows status normalization
set -euo pipefail

FMT="$HOME/.config/nvim/lua/util/dadbod-format.lua"

if [[ ! -f "$FMT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

changed=false

# Revert fallback 1: Query OK line fallback
if grep -qF 'current_status = "(0 rows affected)"' "$FMT"; then
  sed -i 's|current_status = "(0 rows affected)"|current_status = line|' "$FMT"
  echo "  dadbod-format.lua: Query OK fallback restored"
  changed=true
fi

# Revert fallback 2: warnings-only status
if grep -qF 'status = "(0 rows affected)"' "$FMT"; then
  sed -i 's|status = "(0 rows affected)"|status = "Query OK"|' "$FMT"
  echo "  dadbod-format.lua: warnings-only status restored"
  changed=true
fi

if ! $changed; then
  echo "  dadbod-format.lua: already rolled back"
  exit 0
fi

echo ""
echo "restart nvim to apply changes"
