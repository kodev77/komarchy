#!/usr/bin/env bash
# dadbod: rollback <leader>rr binding and get_current_statement helper
set -euo pipefail

HELPERS="$HOME/.config/nvim/lua/util/dadbod-helpers.lua"
KEYMAPS="$HOME/.config/nvim/lua/plugins/dadbod-keymaps.lua"

changed=false

# --- 1. Remove the <leader>rr block ---
if [[ -f "$KEYMAPS" ]] && grep -q '"<leader>rr"' "$KEYMAPS"; then
  awk '
    /^    \{$/ { buf = $0; in_block = 1; next }
    in_block {
      buf = buf "\n" $0
      if ($0 ~ /^    \},$/) {
        if (buf !~ /"<leader>rr"/) {
          print buf
        }
        in_block = 0
        buf = ""
      }
      next
    }
    { print }
  ' "$KEYMAPS" > "$KEYMAPS.tmp" && mv "$KEYMAPS.tmp" "$KEYMAPS"
  echo "  dadbod-keymaps.lua: <leader>rr removed"
  changed=true
fi

# --- 2. Revert <leader>r if it's still on paragraph execution (from older migration state) ---
if [[ -f "$KEYMAPS" ]] && grep -q 'desc = "Execute current statement"' "$KEYMAPS"; then
  awk '
    BEGIN { reverted = 0 }
    /^    \{$/ && !reverted { buf = $0; in_block = 1; next }
    in_block {
      buf = buf "\n" $0
      if ($0 ~ /^    \},$/) {
        if (buf ~ /"<leader>r",/ && buf ~ /get_current_statement/ && buf !~ /mode = "v"/) {
          print "    {"
          print "      \"<leader>r\","
          print "      function()"
          print "        require(\"util.dadbod-helpers\").execute_query(vim.api.nvim_get_current_line())"
          print "      end,"
          print "      ft = { \"sql\", \"mysql\", \"plsql\" },"
          print "      desc = \"Execute current line\","
          print "    },"
          reverted = 1
        } else {
          print buf
        }
        in_block = 0
        buf = ""
      }
      next
    }
    { print }
  ' "$KEYMAPS" > "$KEYMAPS.tmp" && mv "$KEYMAPS.tmp" "$KEYMAPS"
  echo "  dadbod-keymaps.lua: <leader>r reverted to single-line execution"
  changed=true
fi

# --- 3. Remove get_current_statement() from dadbod-helpers.lua ---
if [[ -f "$HELPERS" ]] && grep -q 'function M.get_current_statement()' "$HELPERS"; then
  awk '
    /^--- Get the current SQL statement/ { in_block = 1; next }
    in_block && /^end$/ { in_block = 0; skip_blank = 1; next }
    in_block { next }
    skip_blank && /^$/ { skip_blank = 0; next }
    { skip_blank = 0; print }
  ' "$HELPERS" > "$HELPERS.tmp" && mv "$HELPERS.tmp" "$HELPERS"
  echo "  dadbod-helpers.lua: get_current_statement removed"
  changed=true
fi

if ! $changed; then
  echo "  dadbod <leader>rr: already rolled back"
  exit 0
fi

echo ""
echo "restart nvim to apply changes"
