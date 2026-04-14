#!/usr/bin/env bash
# dadbod: rollback truncation toggle (<leader>ft)
set -euo pipefail

FMT="$HOME/.config/nvim/lua/util/dadbod-format.lua"
AUTOCMDS="$HOME/.config/nvim/lua/plugins/dadbod-autocmds.lua"

changed=false

# --- 1. Remove <leader>ft keybind ---
if [[ -f "$AUTOCMDS" ]] && grep -q 'toggle_truncation' "$AUTOCMDS"; then
  sed -i '/toggle_truncation/d' "$AUTOCMDS"
  echo "  dadbod-autocmds.lua: <leader>ft keybind removed"
  changed=true
fi

# --- 2. Remove toggle_truncation function from format.lua ---
if [[ -f "$FMT" ]] && grep -q 'function M.toggle_truncation()' "$FMT"; then
  awk '
    /^function M.toggle_truncation\(\)/ { in_block = 1; next }
    in_block && /^end$/ { in_block = 0; skip_blank = 1; next }
    in_block { next }
    skip_blank && /^$/ { skip_blank = 0; next }
    { skip_blank = 0; print }
  ' "$FMT" > "$FMT.tmp" && mv "$FMT.tmp" "$FMT"
  echo "  dadbod-format.lua: toggle_truncation removed"
  changed=true
fi

# --- 3. Restore direct max_widths lookups ---
if [[ -f "$FMT" ]] && grep -q 'local max_widths = get_max_widths()' "$FMT"; then
  sed -i 's|local max_widths = get_max_widths()|local max_widths = vim.g.dadbod_format_max_widths or M.max_widths|g' "$FMT"
  echo "  dadbod-format.lua: max_widths lookups restored"
  changed=true
fi

# --- 4. Remove get_max_widths helper ---
if [[ -f "$FMT" ]] && grep -q 'local function get_max_widths()' "$FMT"; then
  awk '
    /^-- Returns max widths respecting the buffer-local truncation toggle/ { in_block = 1; next }
    in_block && /^end$/ { in_block = 0; skip_blank = 1; next }
    in_block { next }
    skip_blank && /^$/ { skip_blank = 0; next }
    { skip_blank = 0; print }
  ' "$FMT" > "$FMT.tmp" && mv "$FMT.tmp" "$FMT"
  echo "  dadbod-format.lua: get_max_widths helper removed"
  changed=true
fi

if ! $changed; then
  echo "  dadbod truncation toggle: already rolled back"
  exit 0
fi

echo ""
echo "restart nvim to apply changes"
