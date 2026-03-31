#!/usr/bin/env bash
# sqlserver: rollback sql server table helpers: column inspector with pk/fk constraints, data types, and nullability
set -euo pipefail

FILE="$HOME/.config/nvim/lua/util/dadbod-tables/sqlserver.lua"

if [[ ! -f "$FILE" ]]; then
  echo "sqlserver table helpers not found, skipping"
  exit 0
fi

echo "removing sqlserver table helpers..."
rm "$FILE"
echo "sqlserver table helpers removed"

echo ""
echo "restart nvim to apply changes"
