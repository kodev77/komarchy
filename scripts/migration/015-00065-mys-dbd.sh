#!/usr/bin/env bash
# mysql: mysql/mariadb table helpers: custom list (limit 200) and count queries for dadbod-ui
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/util/dadbod-tables"

echo "Writing MySQL/MariaDB table helpers..."

cat > "$NVIM_DIR/lua/util/dadbod-tables/mysql.lua" << 'EOF'
-- MySQL/MariaDB table helpers for dadbod-ui
-- On Arch Linux, mysql is provided by MariaDB (wire-compatible)
-- ROW_COUNT() for modifying queries is handled in util/dadbod-helpers.lua
return {
  List = "SELECT * FROM `{table}` LIMIT 200",
  Count = "SELECT COUNT(*) FROM `{table}`",
}
EOF

echo "  util/dadbod-tables/mysql.lua: OK"
