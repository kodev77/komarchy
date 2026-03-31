#!/usr/bin/env bash
# dadbod: vim-dadbod plugin spec: core database interface layer, lazy-loaded by dadbod-ui
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing vim-dadbod plugin spec..."

cat > "$NVIM_DIR/lua/plugins/dadbod.lua" << 'EOF'
-- Core vim-dadbod plugin (lazy-loaded by dadbod-ui)
return { "tpope/vim-dadbod", lazy = true }
EOF

echo "  plugins/dadbod.lua: OK"
