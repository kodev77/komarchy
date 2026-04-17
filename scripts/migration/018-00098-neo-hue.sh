#!/usr/bin/env bash
# neovim: neo-tree highlights selected by omarchy theme hue bucket (green/dark/light/blue/retro/orange/purple)
set -euo pipefail

NVIM_PLUGIN_AFTER="$HOME/.config/nvim/plugin/after"
TRANSPARENCY="$NVIM_PLUGIN_AFTER/transparency.lua"
HUE_FILE="$NVIM_PLUGIN_AFTER/neotree-hue.lua"

echo "Installing neo-tree hue-based highlights..."

mkdir -p "$NVIM_PLUGIN_AFTER"

# remove the flat link block installed by 018-00097, if present
if [[ -f "$TRANSPARENCY" ]] && grep -q 'NeoTreeDirectoryIcon.*link = "Directory"' "$TRANSPARENCY"; then
  sed -i '/-- neo-tree highlights follow active colorscheme/,/NeoTreeRootName/d' "$TRANSPARENCY"
  echo "  transparency.lua: removed flat link block"
fi

cat > "$HUE_FILE" << 'LUAEOF'
-- neo-tree highlights selected by omarchy theme hue bucket.
-- each omarchy theme maps to one hue; each hue returns a neo-tree highlight set.
-- add new themes to `theme_hue` and new buckets to `hue_highlights` as needed.

local function theme_color(key)
  local path = vim.fn.expand("~/.config/omarchy/current/theme/colors.toml")
  if vim.fn.filereadable(path) ~= 1 then return nil end
  for _, line in ipairs(vim.fn.readfile(path)) do
    local val = line:match('^%s*' .. key .. '%s*=%s*"(#%x+)"')
    if val then return val end
  end
  return nil
end

local hue_highlights = {
  -- green: use the omarchy theme's own accent so each green theme gets its own shade
  -- (osaka-jade -> #509475 jade; everforest/others -> their own accent)
  green = function()
    local accent = theme_color("accent") or "#509475"
    -- file name uses the omarchy theme's `foreground` (terminal text color) so it
    -- matches the cream-yellow used in dbout cell text for visual consistency
    local file_fg = theme_color("foreground") or accent
    return {
      NeoTreeDirectoryIcon = { fg = accent },
      NeoTreeDirectoryName = { fg = accent },
      NeoTreeFileName      = { fg = file_fg },
      NeoTreeRootName      = { link = "Title", bold = true },
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
  -- ...
}

local default_highlights = {
  NeoTreeDirectoryIcon = { link = "Directory" },
  NeoTreeDirectoryName = { link = "Directory" },
  NeoTreeRootName      = { link = "Title" },
}

local function current_theme_name()
  local path = vim.fn.expand("~/.config/omarchy/current/theme.name")
  if vim.fn.filereadable(path) ~= 1 then return "" end
  local lines = vim.fn.readfile(path)
  return vim.fn.trim(lines[1] or "")
end

local function apply()
  local hue = theme_hue[current_theme_name()]
  local hl_fn = hue and hue_highlights[hue]
  local hl = (hl_fn and hl_fn()) or default_highlights
  for name, spec in pairs(hl) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

apply()

-- re-apply when the colorscheme changes so link targets resolve against the new palette
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("NeoTreeHue", { clear = true }),
  callback = apply,
})
LUAEOF

echo "  wrote $HUE_FILE"
