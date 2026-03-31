#!/usr/bin/env bash
# dadbod: dadbod autocmds: dbui line select, dbout auto-format with frozen headers, dbselect command
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dadbod autocmds..."

cat > "$NVIM_DIR/lua/plugins/dadbod-autocmds.lua" << 'EOF'
-- Dadbod autocmds: DBUI behavior, dbout auto-formatting, highlights, and DBSelect command
return {
  "kristijanhusak/vim-dadbod-ui",
  config = function()
    -- Dbout highlight groups
    local function set_dbout_highlights()
      vim.api.nvim_set_hl(0, "DboutBorder", { link = "Comment" })
      vim.api.nvim_set_hl(0, "DboutHeader", { link = "Keyword" })
      vim.api.nvim_set_hl(0, "DboutString", { link = "String" })
      vim.api.nvim_set_hl(0, "DboutNumber", { link = "Number" })
      vim.api.nvim_set_hl(0, "DboutGuid", { link = "Type" })
      vim.api.nvim_set_hl(0, "DboutTimestamp", { link = "Function" })
      vim.api.nvim_set_hl(0, "DboutTruncated", { link = "Comment" })
      vim.api.nvim_set_hl(0, "DboutNull", { link = "Comment" })
      vim.api.nvim_set_hl(0, "DboutRowCount", { fg = "#838781", italic = true })
    end
    set_dbout_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = set_dbout_highlights,
    })

    -- User command for connection selection
    vim.api.nvim_create_user_command("DBSelect", function()
      require("util.dadbod-helpers").select_connection()
    end, {})

    local group = vim.api.nvim_create_augroup("dadbod_config", { clear = true })

    -- DBUI: map o to select line
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "dbui",
      callback = function()
        vim.bo.modifiable = true
        vim.keymap.set("n", "o", "<Plug>(DBUI_SelectLine)", { buffer = true })
      end,
    })

    -- dbout: auto-format and keybindings
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "dbout",
      callback = function()
        local fmt = require("util.dadbod-format")
        vim.bo.modifiable = true
        vim.wo.foldenable = false
        fmt.auto_format()
        fmt.setup_frozen_headers(vim.api.nvim_get_current_buf())
        vim.keymap.set("n", "<CR>", fmt.expand_cell, { buffer = true, desc = "Expand cell" })
        vim.keymap.set("n", "<leader>fr", fmt.toggle_raw, { buffer = true, desc = "Toggle raw/formatted" })
        vim.keymap.set("n", "q", fmt.close_expand, { buffer = true, desc = "Close expand" })
      end,
    })

    -- dbout: format on BufEnter if not yet formatted
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function()
        if vim.bo.filetype == "dbout" and vim.b.dbout_is_formatted ~= 1 then
          require("util.dadbod-format").format()
        end
      end,
    })
  end,
}
EOF

echo "  plugins/dadbod-autocmds.lua: OK"
