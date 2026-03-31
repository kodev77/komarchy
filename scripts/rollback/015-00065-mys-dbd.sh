#!/usr/bin/env bash
# mysql: rollback mysql/mariadb table helpers: custom list (limit 200) and count queries for dadbod-ui
set -euo pipefail

FILE="$HOME/.config/nvim/lua/util/dadbod-tables/mysql.lua"

if [[ ! -f "$FILE" ]]; then
  echo "mysql table helpers not found, skipping"
  exit 0
fi

echo "removing mysql table helpers..."
rm "$FILE"
echo "mysql table helpers removed"

echo ""
echo "restart nvim to apply changes"
