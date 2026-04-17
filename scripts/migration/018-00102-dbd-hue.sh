#!/usr/bin/env bash
# dadbod: dbout highlights pick per-hue-bucket colors from omarchy colors.toml (mirrors neotree-hue)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
AUTOCMDS="$NVIM_DIR/lua/plugins/dadbod-autocmds.lua"

if [[ ! -f "$AUTOCMDS" ]]; then
  echo "dadbod-autocmds.lua not found, skipping"
  exit 0
fi

echo "adding hue-bucket overrides to dbout highlights..."

cat > "$AUTOCMDS" << 'EOF'
-- Dadbod autocmds: DBUI behavior, dbout auto-formatting, highlights, and DBSelect command
return {
  "kristijanhusak/vim-dadbod-ui",
  config = function()
    -- Dbout highlights: 3 tones (+ NULL italic). Green-bucket themes pull
    -- border/data colors from omarchy's colors.toml so the table reads on-theme
    -- instead of defaulting to the colorscheme's Normal (often cream/white).
    -- Theme -> hue mapping mirrors ~/.config/nvim/plugin/after/neotree-hue.lua

    local function theme_color(key)
      local path = vim.fn.expand("~/.config/omarchy/current/theme/colors.toml")
      if vim.fn.filereadable(path) ~= 1 then return nil end
      for _, line in ipairs(vim.fn.readfile(path)) do
        local val = line:match("^%s*" .. key .. "%s*=%s*\"(#%x+)\"")
        if val then return val end
      end
      return nil
    end

    local function current_theme_name()
      local path = vim.fn.expand("~/.config/omarchy/current/theme.name")
      if vim.fn.filereadable(path) ~= 1 then return "" end
      return vim.fn.trim(vim.fn.readfile(path)[1] or "")
    end

    local default_highlights = {
      DboutBorder = { link = "Comment" },
      DboutHeader = { link = "Title" },
      DboutData   = { link = "Normal" },
      DboutNull   = { italic = true },
    }

    local hue_highlights = {
      green = function()
        local border = theme_color("color8")
        -- use the omarchy theme's `foreground` so cells render as cream-yellow
        -- (ghostty's text color) instead of color10 bright green
        local data   = theme_color("foreground")
        return {
          DboutBorder = border and { fg = border } or default_highlights.DboutBorder,
          DboutHeader = default_highlights.DboutHeader,
          DboutData   = data   and { fg = data   } or default_highlights.DboutData,
          DboutNull   = default_highlights.DboutNull,
        }
      end,
      -- dark   = function() return { ... } end,
      -- light  = function() return { ... } end,
      -- blue   = function() return { ... } end,
      -- retro  = function() return { ... } end,
      -- orange = function() return { ... } end,
      -- purple = function() return { ... } end,
    }

    local theme_hue = {
      ["osaka-jade"] = "green",
      ["gruvbox"]    = "green",
      ["miasma"]     = "green",
      -- ["tokyo-night"]      = "dark",
      -- ["catppuccin"]       = "purple",
      -- ["catppuccin-latte"] = "light",
      -- ["rose-pine"]        = "purple",
    }

    local function set_dbout_highlights()
      local hue_fn = hue_highlights[theme_hue[current_theme_name()] or ""]
      local hl = (hue_fn and hue_fn()) or default_highlights
      for name, spec in pairs(hl) do
        vim.api.nvim_set_hl(0, name, spec)
      end
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

echo "  plugins/dadbod-autocmds.lua: hue-bucket overrides added (green -> color8/color10)"
