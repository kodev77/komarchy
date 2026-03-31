#!/usr/bin/env bash
# dadbod: blink.cmp integration: registers dadbod-completion as a source for sql filetypes
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dadbod blink.cmp integration..."

cat > "$NVIM_DIR/lua/plugins/dadbod-blink.lua" << 'EOF'
-- Blink.cmp integration: register vim-dadbod-completion as a source provider
-- for SQL filetypes so autocomplete suggests table/column names
return {
  "saghen/blink.cmp",
  optional = true,
  opts = {
    sources = {
      per_filetype = {
        sql = { inherit_defaults = true, "dadbod" },
        mysql = { inherit_defaults = true, "dadbod" },
        plsql = { inherit_defaults = true, "dadbod" },
      },
      providers = {
        dadbod = {
          name = "Dadbod",
          module = "vim_dadbod_completion.blink",
        },
      },
    },
  },
}
EOF

echo "  plugins/dadbod-blink.lua: OK"
