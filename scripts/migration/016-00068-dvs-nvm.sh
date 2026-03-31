#!/usr/bin/env bash
# dataverse: dadbod table helpers for dataverse (list, columns, count)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/util/dadbod-tables"

echo "Writing Dataverse table helpers..."

cat > "$NVIM_DIR/lua/util/dadbod-tables/dataverse.lua" << 'EOF'
-- Dataverse table helpers for dadbod-ui (used with custom dvquery adapter)
return {
  List = "SELECT TOP 200 * FROM {table}",
  Columns = ".columns {table}",
  Count = "SELECT COUNT(*) FROM {table}",
}
EOF

echo "  util/dadbod-tables/dataverse.lua: OK"
