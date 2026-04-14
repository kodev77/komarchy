#!/usr/bin/env bash
# dadbod: add <leader>rr to execute the current SQL statement (paragraph); <leader>r stays as current line
set -euo pipefail

HELPERS="$HOME/.config/nvim/lua/util/dadbod-helpers.lua"
KEYMAPS="$HOME/.config/nvim/lua/plugins/dadbod-keymaps.lua"

if [[ ! -f "$HELPERS" || ! -f "$KEYMAPS" ]]; then
  echo "dadbod-helpers.lua or dadbod-keymaps.lua not found, skipping"
  exit 0
fi

changed=false

# --- 1. Inject get_current_statement() into dadbod-helpers.lua ---
if ! grep -q 'function M.get_current_statement()' "$HELPERS"; then
  awk '
    /^--- Get text from visual selection/ && !inserted {
      print "--- Get the current SQL statement around the cursor"
      print "--- Boundaries: blank lines OR a semicolon terminator at end of line"
      print "function M.get_current_statement()"
      print "  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]"
      print "  local total = vim.api.nvim_buf_line_count(0)"
      print ""
      print "  local function is_blank(l)"
      print "    return vim.fn.getline(l):match(\"^%s*$\") ~= nil"
      print "  end"
      print ""
      print "  local function ends_with_semi(l)"
      print "    return vim.fn.getline(l):match(\";%s*$\") ~= nil"
      print "  end"
      print ""
      print "  if is_blank(cursor_line) then"
      print "    return \"\""
      print "  end"
      print ""
      print "  local start_line = cursor_line"
      print "  while start_line > 1 do"
      print "    local prev = start_line - 1"
      print "    if is_blank(prev) or ends_with_semi(prev) then"
      print "      break"
      print "    end"
      print "    start_line = prev"
      print "  end"
      print ""
      print "  local end_line = cursor_line"
      print "  while end_line < total do"
      print "    if ends_with_semi(end_line) then"
      print "      break"
      print "    end"
      print "    if is_blank(end_line + 1) then"
      print "      break"
      print "    end"
      print "    end_line = end_line + 1"
      print "  end"
      print ""
      print "  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)"
      print "  return table.concat(lines, \"\\n\")"
      print "end"
      print ""
      inserted = 1
    }
    { print }
  ' "$HELPERS" > "$HELPERS.tmp" && mv "$HELPERS.tmp" "$HELPERS"
  echo "  dadbod-helpers.lua: get_current_statement injected"
  changed=true
fi

# --- 2. Revert <leader>r to single-line execution if a prior version hijacked it ---
if grep -q 'desc = "Execute current statement"' "$KEYMAPS" \
   && ! grep -q '"<leader>rr"' "$KEYMAPS"; then
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

# --- 3. Insert <leader>rr block after the normal-mode <leader>r block ---
if ! grep -q '"<leader>rr"' "$KEYMAPS"; then
  awk '
    BEGIN { inserted = 0 }
    /^    \{$/ { buf = $0; in_block = 1; next }
    in_block {
      buf = buf "\n" $0
      if ($0 ~ /^    \},$/) {
        print buf
        if (!inserted && buf ~ /"<leader>r",/ && buf ~ /nvim_get_current_line/ && buf !~ /mode = "v"/) {
          print "    {"
          print "      \"<leader>rr\","
          print "      function()"
          print "        local h = require(\"util.dadbod-helpers\")"
          print "        h.execute_query(h.get_current_statement())"
          print "      end,"
          print "      ft = { \"sql\", \"mysql\", \"plsql\" },"
          print "      desc = \"Execute current statement\","
          print "    },"
          inserted = 1
        }
        in_block = 0
        buf = ""
      }
      next
    }
    { print }
  ' "$KEYMAPS" > "$KEYMAPS.tmp" && mv "$KEYMAPS.tmp" "$KEYMAPS"
  echo "  dadbod-keymaps.lua: <leader>rr added (executes current statement)"
  changed=true
fi

if ! $changed; then
  echo "  dadbod <leader>rr: already patched"
  exit 0
fi

echo ""
echo "restart nvim to apply changes"
