#!/usr/bin/env bash
# dadbod: add <leader>ft toggle to switch dbout columns between truncated and full widths
set -euo pipefail

FMT="$HOME/.config/nvim/lua/util/dadbod-format.lua"
AUTOCMDS="$HOME/.config/nvim/lua/plugins/dadbod-autocmds.lua"

if [[ ! -f "$FMT" || ! -f "$AUTOCMDS" ]]; then
  echo "dadbod-format.lua or dadbod-autocmds.lua not found, skipping"
  exit 0
fi

changed=false

# --- 1. Inject get_max_widths() helper into dadbod-format.lua ---
if ! grep -q 'local function get_max_widths()' "$FMT"; then
  awk '
    /^-- Box-drawing characters/ && !inserted {
      print "-- Returns max widths respecting the buffer-local truncation toggle"
      print "local function get_max_widths()"
      print "  if vim.b.dbout_truncation_disabled then"
      print "    return { guid = 10000, timestamp = 10000, number = 10000, json = 10000, default = 10000 }"
      print "  end"
      print "  return vim.g.dadbod_format_max_widths or M.max_widths"
      print "end"
      print ""
      inserted = 1
    }
    { print }
  ' "$FMT" > "$FMT.tmp" && mv "$FMT.tmp" "$FMT"
  echo "  dadbod-format.lua: get_max_widths helper injected"
  changed=true
fi

# --- 2. Replace direct max_widths lookups with get_max_widths() ---
if grep -q 'local max_widths = vim.g.dadbod_format_max_widths or M.max_widths' "$FMT"; then
  sed -i 's|local max_widths = vim.g.dadbod_format_max_widths or M.max_widths|local max_widths = get_max_widths()|g' "$FMT"
  echo "  dadbod-format.lua: max_widths lookups routed through get_max_widths"
  changed=true
fi

# --- 3. Inject M.toggle_truncation() before return M ---
if ! grep -q 'function M.toggle_truncation()' "$FMT"; then
  awk '
    /^return M$/ && !inserted {
      print "function M.toggle_truncation()"
      print "  local raw_content = vim.b.dbout_raw_content"
      print "  if not raw_content then"
      print "    vim.notify(\"No raw content stored\")"
      print "    return"
      print "  end"
      print ""
      print "  vim.b.dbout_truncation_disabled = not vim.b.dbout_truncation_disabled"
      print ""
      print "  vim.bo.modifiable = true"
      print "  vim.api.nvim_buf_set_lines(0, 0, -1, false, raw_content)"
      print "  vim.bo.modifiable = false"
      print "  vim.b.dbout_is_formatted = 0"
      print "  M.format()"
      print ""
      print "  if vim.b.dbout_truncation_disabled then"
      print "    vim.notify(\"Showing full column widths\")"
      print "  else"
      print "    vim.notify(\"Showing truncated columns\")"
      print "  end"
      print "end"
      print ""
      inserted = 1
    }
    { print }
  ' "$FMT" > "$FMT.tmp" && mv "$FMT.tmp" "$FMT"
  echo "  dadbod-format.lua: toggle_truncation added"
  changed=true
fi

# --- 4. Add <leader>ft keybind in dadbod-autocmds.lua ---
if ! grep -q 'toggle_truncation' "$AUTOCMDS"; then
  awk '
    /vim\.keymap\.set\("n", "<leader>fr", fmt\.toggle_raw/ && !inserted {
      print
      print "        vim.keymap.set(\"n\", \"<leader>ft\", fmt.toggle_truncation, { buffer = true, desc = \"Toggle truncation\" })"
      inserted = 1
      next
    }
    { print }
  ' "$AUTOCMDS" > "$AUTOCMDS.tmp" && mv "$AUTOCMDS.tmp" "$AUTOCMDS"
  echo "  dadbod-autocmds.lua: <leader>ft keybind added"
  changed=true
fi

if ! $changed; then
  echo "  dadbod truncation toggle: already patched"
  exit 0
fi

echo ""
echo "restart nvim to apply changes"
