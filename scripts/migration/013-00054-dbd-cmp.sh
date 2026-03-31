#!/usr/bin/env bash
# dadbod: dadbod-completion plugin spec: sql autocomplete source for table and column names
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dadbod-completion plugin spec..."

cat > "$NVIM_DIR/lua/plugins/dadbod-completion.lua" << 'EOF'
-- vim-dadbod-completion: SQL completion source for dadbod
return {
  "kristijanhusak/vim-dadbod-ui",
  dependencies = {
    { "kristijanhusak/vim-dadbod-completion", ft = { "sql", "mysql", "plsql" }, lazy = true },
  },
}
EOF

echo "  plugins/dadbod-completion.lua: OK"
