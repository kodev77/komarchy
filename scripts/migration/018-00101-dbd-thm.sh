#!/usr/bin/env bash
# dadbod: simplify dbout highlight groups to 3 (Border / Header / Data) + NULL italic variant
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
AUTOCMDS="$NVIM_DIR/lua/plugins/dadbod-autocmds.lua"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$AUTOCMDS" || ! -f "$FORMAT" ]]; then
  echo "dadbod files not found, skipping"
  exit 0
fi

echo "simplifying dbout highlight groups to 3 tones..."

# 1. Rewrite dadbod-autocmds.lua with 3-group highlights
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
echo "  plugins/dadbod-autocmds.lua: 3 highlight groups (Border/Header/Data + Null italic)"

# 2. Patch dadbod-format.lua

# 2a. Row-count lines fold into Border "chrome" group. Use address range so we only
#     rename the DboutRowCount occurrence, not any future DboutBorder uses.
sed -i '/-- Row count header lines/,/goto continue_line/{s/hl_group = "DboutRowCount"/hl_group = "DboutBorder"/;}' "$FORMAT"

# 2b. Collapse per-type branching to a single DboutData/DboutNull check.
if grep -q 'hl_group = "DboutGuid"' "$FORMAT"; then
  sed -i '/-- Check for NULL - override type color/,/^        end$/c\
        -- dbout cell highlight: NULL uses italic variant, all others use DboutData\
        local val_text = cell_content:sub(val_start_offset, val_end_offset)\
        local hl_group = val_text == "NULL" and "DboutNull" or "DboutData"' "$FORMAT"
  echo "  util/dadbod-format.lua: cell-type branching collapsed"
else
  echo "  util/dadbod-format.lua: already simplified, skipping"
fi
