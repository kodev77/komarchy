#!/usr/bin/env bash
# dadbod: lua utilities for query execution, visual selection, connection picker, and popup clipboard
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/util"

echo "Writing dadbod connection and query helpers..."

cat > "$NVIM_DIR/lua/util/dadbod-helpers.lua" << 'EOF'
-- Dadbod helper utilities: query execution, connection management, and clipboard
local M = {}

--- Execute a SQL query via vim-dadbod
--- For MySQL/MariaDB modifying queries, appends ROW_COUNT() to show affected rows
function M.execute_query(query)
  query = vim.trim(query)
  if query == "" then
    return
  end

  local db = vim.b.db or vim.g.db or ""
  local is_mysql = db:lower():match("^mysql:")
  local is_modify = query:match("^%s*[Uu][Pp][Dd][Aa][Tt][Ee]%s")
    or query:match("^%s*[Dd][Ee][Ll][Ee][Tt][Ee]%s")
    or query:match("^%s*[Ii][Nn][Ss][Ee][Rr][Tt]%s")

  if is_mysql and is_modify then
    query = query:gsub("%s*;%s*$", "")
    query = query .. "; SELECT ROW_COUNT() as rows_affected;"
  end

  -- Collapse newlines to spaces
  query = query:gsub("\n", " ")

  -- Write to temp file to avoid command-line parsing issues
  local tmpfile = vim.fn.tempname() .. ".sql"
  vim.fn.writefile({ query }, tmpfile)
  vim.cmd("DB < " .. vim.fn.fnameescape(tmpfile))
end

--- Get text from visual selection
function M.get_visual_selection()
  local _, ls, cs = unpack(vim.fn.getpos("'<"))
  local _, le, ce = unpack(vim.fn.getpos("'>"))
  local lines = vim.api.nvim_buf_get_text(0, ls - 1, cs - 1, le - 1, ce, {})
  return table.concat(lines, "\n")
end

--- Copy floating window content to clipboard
function M.copy_popup_content()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative and config.relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if #lines > 0 then
        vim.fn.setreg("+", table.concat(lines, "\n"))
        vim.notify("Copied " .. #lines .. " lines to clipboard")
        return
      end
    end
  end
  vim.notify("No popups visible")
end

--- Select a database connection using Snacks.picker
function M.select_connection()
  local save_loc = vim.g.db_ui_save_location or vim.fn.expand("~/.local/share/db_ui")
  local conn_file = save_loc .. "/connections.json"

  if vim.fn.filereadable(conn_file) == 0 then
    vim.notify("No saved connections found at " .. conn_file)
    return
  end

  local json_str = table.concat(vim.fn.readfile(conn_file), "")
  local ok, connections = pcall(vim.json.decode, json_str)
  if not ok or not connections or #connections == 0 then
    vim.notify("No connections configured")
    return
  end

  local items = {}
  local urls = {}
  for _, conn in ipairs(connections) do
    local name = conn.name or ""
    local url = conn.url or ""
    if name ~= "" and url ~= "" then
      urls[name] = url
      items[#items + 1] = { text = name, name = name }
    end
  end

  if #items == 0 then
    vim.notify("No connections configured")
    return
  end

  Snacks.picker({
    title = "Select DB Connection",
    items = items,
    format = "text",
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.b.db = urls[item.name]
        vim.b.db_name = item.name
        vim.notify("Connected to: " .. item.name)
      end
    end,
  })
end

--- Show current database connection
function M.show_connection()
  local name = vim.b.db_name or ""
  local url = vim.b.db or vim.g.db or ""
  if name == "" then
    local db_ok, statusline = pcall(vim.fn["db_ui#statusline"], { prefix = "", show = { "db_name" } })
    if db_ok then
      name = statusline
    end
  end
  if name ~= "" and url ~= "" then
    vim.notify("DB: " .. name .. "  " .. url)
  elseif url ~= "" then
    vim.notify("DB: " .. url)
  else
    vim.notify("No database connection")
  end
end

return M
EOF

echo "  util/dadbod-helpers.lua: OK"
