#!/usr/bin/env bash
# dadbod: dadbod-ui plugin spec: database browser sidebar with nerd fonts and saved connections
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dadbod-ui plugin spec..."

cat > "$NVIM_DIR/lua/plugins/dadbod-ui.lua" << 'EOF'
-- vim-dadbod-ui: database browser interface
return {
  "kristijanhusak/vim-dadbod-ui",
  dependencies = {
    { "tpope/vim-dadbod", lazy = true },
  },
  cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer", "DBUILastQueryInfo" },
  init = function()
    vim.g.db_ui_use_nerd_fonts = 1
    vim.g.db_ui_show_database_icon = 1
    vim.g.db_ui_win_position = "left"
    vim.g.db_ui_winwidth = 40
    vim.g.db_ui_save_location = vim.fn.expand("~/.local/share/db_ui")
    vim.g.db_ui_execute_on_save = 0

    -- Load table helpers from util/dadbod-tables/ (added by db adapter migrations)
    local helpers = {}
    local tables_dir = vim.fn.stdpath("config") .. "/lua/util/dadbod-tables"
    if vim.fn.isdirectory(tables_dir) == 1 then
      for _, file in ipairs(vim.fn.glob(tables_dir .. "/*.lua", false, true)) do
        local name = vim.fn.fnamemodify(file, ":t:r")
        local ok, tbl = pcall(dofile, file)
        if ok and tbl then
          helpers[name] = tbl
        end
      end
    end
    vim.g.db_ui_table_helpers = helpers
  end,
}
EOF

echo "  plugins/dadbod-ui.lua: OK"
