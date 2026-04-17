#!/usr/bin/env bash
# dadbod: rollback dbout color simplification (restore 9 type-specific highlight groups)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
AUTOCMDS="$NVIM_DIR/lua/plugins/dadbod-autocmds.lua"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$AUTOCMDS" || ! -f "$FORMAT" ]]; then
  echo "dadbod files not found, skipping"
  exit 0
fi

echo "restoring dbout type-specific highlights..."

# 1. Rewrite dadbod-autocmds.lua with the original 9-group content
cat > "$AUTOCMDS" << 'EOF'
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
echo "  plugins/dadbod-autocmds.lua: restored 9 highlight groups"

# 2. Reverse-patch format.lua

# 2a. Restore DboutRowCount within the row-count address range (avoids touching the real DboutBorder line below)
sed -i '/-- Row count header lines/,/goto continue_line/{s/hl_group = "DboutBorder"/hl_group = "DboutRowCount"/;}' "$FORMAT"

# 2b. Expand the collapsed block back to the full type-specific branching
if grep -q 'NULL uses italic variant, all others use DboutData' "$FORMAT"; then
  sed -i '/-- dbout cell highlight: NULL uses italic variant/,/local hl_group = val_text == "NULL" and "DboutNull" or "DboutData"/c\
        -- Check for NULL - override type color\
        local val_text = cell_content:sub(val_start_offset, val_end_offset)\
        local hl_group\
        if val_text == "NULL" then\
          hl_group = "DboutNull"\
        elseif val_text:find("%.%.%.$") then\
          hl_group = "DboutTruncated"\
        elseif col_type == "guid" then\
          hl_group = "DboutGuid"\
        elseif col_type == "timestamp" then\
          hl_group = "DboutTimestamp"\
        elseif col_type == "number" then\
          hl_group = "DboutNumber"\
        else\
          hl_group = "DboutString"\
        end' "$FORMAT"
  echo "  util/dadbod-format.lua: cell-type branching restored"
else
  echo "  util/dadbod-format.lua: already has full branching, skipping"
fi
