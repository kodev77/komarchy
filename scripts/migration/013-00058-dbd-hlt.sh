#!/usr/bin/env bash
# dadbod: dbout highlight groups for borders, headers, types, nulls; re-applied on colorscheme change
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dadbod dbout highlight groups..."

cat > "$NVIM_DIR/lua/plugins/dadbod-highlights.lua" << 'EOF'
-- Dbout highlights are now merged into dadbod-autocmds.lua
-- This file kept for migration state tracking
return {}
EOF

echo "  plugins/dadbod-highlights.lua: OK"
