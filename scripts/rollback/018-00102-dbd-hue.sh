#!/usr/bin/env bash
# dadbod: rollback dbout hue-bucket overrides (restore the 018-00101 simple semantic-link version)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
AUTOCMDS="$NVIM_DIR/lua/plugins/dadbod-autocmds.lua"

if [[ ! -f "$AUTOCMDS" ]]; then
  echo "dadbod-autocmds.lua not found, skipping"
  exit 0
fi

echo "removing hue-bucket overrides, restoring 3-tone semantic links..."

cat > "$AUTOCMDS" << 'EOF'
-- Dadbod autocmds: DBUI behavior, dbout auto-formatting, highlights, and DBSelect command
return {
  "kristijanhusak/vim-dadbod-ui",
  config = function()
    -- Dbout highlight groups: 3 tones total (+ NULL as italic variant of Data)
    local function set_dbout_highlights()
      vim.api.nvim_set_hl(0, "DboutBorder", { link = "Comment" })
      vim.api.nvim_set_hl(0, "DboutHeader", { link = "Title" })
      vim.api.nvim_set_hl(0, "DboutData",   { link = "Normal" })
      vim.api.nvim_set_hl(0, "DboutNull",   { italic = true })
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
        vim.keymap.set("n", "<leader>ft", fmt.toggle_truncation, { buffer = true, desc = "Toggle truncation" })
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

echo "  plugins/dadbod-autocmds.lua: restored 3-tone semantic-link version (018-00101 state)"
