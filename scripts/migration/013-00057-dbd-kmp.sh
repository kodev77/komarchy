#!/usr/bin/env bash
# dadbod: dadbod keybindings: dbui toggle, run line/selection/file, connection select, format output
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dadbod keymaps..."

cat > "$NVIM_DIR/lua/plugins/dadbod-keymaps.lua" << 'EOF'
-- Dadbod keybindings for DBUI, query execution, and connection management
return {
  "kristijanhusak/vim-dadbod-ui",
  keys = {
    {
      "<leader>Db",
      function()
        -- Close neo-tree if open
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == "neo-tree" then
            vim.api.nvim_win_close(win, true)
          end
        end
        -- Replace dashboard with empty buffer
        local ft = vim.bo.filetype
        if ft == "snacks_dashboard" or ft == "alpha" or ft == "starter" or ft == "dashboard" then
          vim.cmd("enew")
        end
        vim.cmd("DBUIToggle")
      end,
      desc = "Toggle DBUI",
    },
    { "<leader>Df", "<cmd>DBUIFindBuffer<CR>", desc = "Find DB buffer" },
    { "<leader>Dl", "<cmd>DBUILastQueryInfo<CR>", desc = "Last query info" },
    {
      "<leader>Ds",
      function()
        require("util.dadbod-helpers").select_connection()
      end,
      desc = "Select DB connection",
    },
    {
      "<leader>Dc",
      function()
        require("util.dadbod-helpers").show_connection()
      end,
      desc = "Show DB connection",
    },
    {
      "<leader>DF",
      function()
        require("util.dadbod-format").format_from_anywhere()
      end,
      desc = "Format DB output",
    },
    {
      "<leader>r",
      function()
        require("util.dadbod-helpers").execute_query(vim.api.nvim_get_current_line())
      end,
      ft = { "sql", "mysql", "plsql" },
      desc = "Execute current line",
    },
    {
      "<leader>r",
      function()
        require("util.dadbod-helpers").execute_query(require("util.dadbod-helpers").get_visual_selection())
      end,
      mode = "v",
      ft = { "sql", "mysql", "plsql" },
      desc = "Execute selection",
    },
    {
      "<leader>R",
      function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        require("util.dadbod-helpers").execute_query(table.concat(lines, "\n"))
      end,
      ft = { "sql", "mysql", "plsql" },
      desc = "Execute entire file",
    },
    {
      "<leader>cp",
      function()
        require("util.dadbod-helpers").copy_popup_content()
      end,
      desc = "Copy popup content",
    },
  },
}
EOF

echo "  plugins/dadbod-keymaps.lua: OK"
