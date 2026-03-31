-- dadbod-format.lua - SQL output formatting for vim-dadbod
-- Provides bordered tables, column alignment, truncation, and cell expansion
-- Ported from VimScript to Lua for LuaJIT performance

local M = {}

-- Configuration
M.max_widths = {
  guid = 15,
  timestamp = 22,
  number = 15,
  json = 20,
  default = 40,
}

-- Box-drawing characters
local box = {
  tl = "\xe2\x94\x8c", -- ┌
  tr = "\xe2\x94\x90", -- ┐
  bl = "\xe2\x94\x94", -- └
  br = "\xe2\x94\x98", -- ┘
  h = "\xe2\x94\x80", -- ─
  v = "\xe2\x94\x82", -- │
  lm = "\xe2\x94\x9c", -- ├
  rm = "\xe2\x94\xa4", -- ┤
  tm = "\xe2\x94\xac", -- ┬
  bm = "\xe2\x94\xb4", -- ┴
  mm = "\xe2\x94\xbc", -- ┼
}

-- Polling state
local poll_timer = nil
local poll_count = 0
local poll_max = 150 -- 150 * 200ms = 30 seconds
local last_line_count = 0
local stable_count = 0

-- Extmark namespace for highlighting
local ns_id = vim.api.nvim_create_namespace("dbout_format")

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function displaywidth(str)
  -- Fast path: pure ASCII strings (common for SQL data)
  -- ASCII bytes are 0x00-0x7F; if no byte exceeds 0x7F, byte length == display width
  if not str:find("[\x80-\xff]") then
    return #str
  end
  return vim.fn.strdisplaywidth(str)
end

local function split_and_trim(line, delim)
  local parts = vim.split(line, delim, { plain = true })
  -- Trim each part
  for i, part in ipairs(parts) do
    parts[i] = vim.trim(part)
  end
  -- Remove empty elements at start and end (from leading/trailing delimiters)
  while #parts > 0 and parts[1] == "" do
    table.remove(parts, 1)
  end
  while #parts > 0 and parts[#parts] == "" do
    table.remove(parts)
  end
  return parts
end

-- ============================================================================
-- TABLE NAME EXTRACTION
-- ============================================================================

local function extract_table_names()
  local input_file = vim.b.db_input or ""
  if input_file == "" or vim.fn.filereadable(input_file) == 0 then
    return {}
  end
  local lines = vim.fn.readfile(input_file)
  local query = table.concat(lines, " ")
  if query == "" then
    return {}
  end

  local names = {}

  -- Extract table names from FROM clauses
  -- Pattern: FROM [optional quotes] table_name
  local search_pos = 1
  while true do
    -- Case-insensitive search for FROM keyword
    local from_start, from_end = query:lower():find("%f[%a]from%f[%A]", search_pos)
    if not from_start then
      break
    end
    -- Get the table name after FROM (skip optional quotes/brackets)
    local after_from = query:sub(from_end + 1)
    local name = after_from:match("^%s+[`\"%[]*([%a_][%w_]*%.?[%a_][%w_]*)")
      or after_from:match("^%s+[`\"%[]*([%a_][%w_]*)")
    if name then
      -- If schema.table, use just the table name
      local dot_pos = name:find("%.")
      if dot_pos then
        name = name:sub(dot_pos + 1)
      end
      names[#names + 1] = name
    end
    search_pos = from_end + 1
  end

  -- Also check for UPDATE/INSERT INTO if no FROM found
  if #names == 0 then
    local name = query:match("%f[%a][Uu][Pp][Dd][Aa][Tt][Ee]%s+[`\"%[]*([%a_][%w_]*)")
      or query:match("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+[`\"%[]*([%a_][%w_]*)")
    if name then
      names[#names + 1] = name
    end
  end

  return names
end

-- ============================================================================
-- PARSING FUNCTIONS
-- ============================================================================

local function try_parse_with_delimiter(lines, delim)
  local result = { headers = {}, rows = {} }
  local data_lines = {}

  for _, line in ipairs(lines) do
    -- Skip separator lines
    if
      line:match("^[-+\xe2\x94\x80\xe2\x94\xac\xe2\x94\xbc\xe2\x94\xb4\xe2\x94\x9c\xe2\x94\xa4\xe2\x94\x8c\xe2\x94\x90\xe2\x94\x94\xe2\x94\x98\xe2\x94\x82=]+%s*$")
      or line:match("^[%s|+%-]*$")
      or line:match("^[%-%s]+$")
      or line:match("^%+[-+]+%+%s*$")
    then
      goto continue
    end
    -- Skip database warning/info lines
    if
      line:match("^%s*mysql:")
      or line:match("^%s*mariadb:")
      or line:match("^%s*psql:")
      or line:match("^/.+/mysql:")
      or line:match("^/.+/mariadb:")
      or line:match("Deprecated program name")
      or line:match("%[Warning%]")
      or line:match("%[Note%]")
      or line:match("%[Error%]")
    then
      goto continue
    end
    -- Skip empty lines
    if vim.trim(line) == "" then
      goto continue
    end
    data_lines[#data_lines + 1] = line
    ::continue::
  end

  if #data_lines == 0 then
    return result
  end

  -- Reject if delimiter not present in header line
  if not data_lines[1]:find(delim, 1, true) then
    return result
  end

  -- First non-empty line is headers
  result.headers = split_and_trim(data_lines[1], delim)

  -- Remaining lines are data rows
  for i = 2, #data_lines do
    local row = split_and_trim(data_lines[i], delim)
    if #row > 0 then
      result.rows[#result.rows + 1] = row
    end
  end

  -- Validate: headers and rows should have same column count
  if #result.rows > 0 then
    local header_count = #result.headers
    local row_count = #result.rows[1]
    if header_count ~= row_count and header_count > 1 then
      return { headers = {}, rows = {} }
    end
  end

  -- Reject if only 1 column but line is long (probably wrong delimiter)
  if #result.headers == 1 and #data_lines[1] > 50 then
    return { headers = {}, rows = {} }
  end

  return result
end

local function get_column_positions(sep_line)
  local positions = {}
  local in_col = false
  local start = 0

  for i = 1, #sep_line do
    local char = sep_line:sub(i, i)
    if char == "-" then
      if not in_col then
        start = i
        in_col = true
      end
    else
      if in_col then
        positions[#positions + 1] = { start, i - 1 }
        in_col = false
      end
    end
  end
  -- Handle last column
  if in_col then
    positions[#positions + 1] = { start, #sep_line }
  end
  return positions
end

local function extract_fixed_columns(line, positions)
  local cols = {}
  for _, pos in ipairs(positions) do
    local s, e = pos[1], pos[2]
    if s <= #line then
      local actual_end = math.min(e, #line)
      local val = line:sub(s, actual_end)
      cols[#cols + 1] = vim.trim(val)
    else
      cols[#cols + 1] = ""
    end
  end
  return cols
end

local function parse_fixed_width(lines)
  local result = { headers = {}, rows = {} }
  local data_lines = {}
  local separator_idx = nil

  -- Find the separator line (---- ---- ----)
  for i, line in ipairs(lines) do
    if line:match("^%-+%s+%-+") or line:match("^%-+$") then
      separator_idx = i
      break
    end
    if vim.trim(line) ~= "" then
      data_lines[#data_lines + 1] = line
    end
  end

  if not separator_idx then
    -- No separator found, treat first line as headers
    if #data_lines == 0 then
      return result
    end
    result.headers = vim.split(data_lines[1], "%s+")
    for i = 2, #data_lines do
      result.rows[#result.rows + 1] = vim.split(data_lines[i], "%s+")
    end
    return result
  end

  -- Parse based on separator positions
  local sep_line = lines[separator_idx]
  local col_positions = get_column_positions(sep_line)

  -- Header is line before separator
  if separator_idx > 1 then
    result.headers = extract_fixed_columns(lines[separator_idx - 1], col_positions)
  end

  -- Data rows are lines after separator
  for i = separator_idx + 1, #lines do
    local line = lines[i]
    if vim.trim(line) == "" then
      goto continue
    end
    -- Stop at row count line
    if line:match("^%s*%(?%d+ rows? affected%)") then
      break
    end
    local row = extract_fixed_columns(line, col_positions)
    if #row > 0 then
      result.rows[#result.rows + 1] = row
    end
    ::continue::
  end

  return result
end

local function parse_output(lines)
  -- First, try explicit MySQL format detection
  local has_mysql_border = false
  local has_pipe_data = false
  for _, line in ipairs(lines) do
    if line:match("^%+[-+]+%+%s*$") then
      has_mysql_border = true
    end
    if line:match("^|.+|$") then
      has_pipe_data = true
    end
    if has_mysql_border and has_pipe_data then
      break
    end
  end

  -- If MySQL format detected, parse with pipe delimiter
  if has_mysql_border and has_pipe_data then
    local parsed = try_parse_with_delimiter(lines, "|")
    if #parsed.headers > 0 and #parsed.rows > 0 then
      return parsed
    end
  end

  -- Try different delimiters
  local delimiters = { "|", "\t", "," }
  for _, delim in ipairs(delimiters) do
    local parsed = try_parse_with_delimiter(lines, delim)
    if #parsed.headers > 0 and #parsed.rows > 0 then
      return parsed
    end
  end

  -- Fallback: fixed-width parsing (SQL Server)
  return parse_fixed_width(lines)
end

-- ============================================================================
-- SPLIT RESULT SETS
-- ============================================================================

local function split_result_sets(lines)
  local result_sets = {}
  local current_set = {}
  local current_status = ""
  local in_data = false

  for _, line in ipairs(lines) do
    -- Detect row count lines
    if
      line:match("^%s*%(?%d+%s+rows?%s*affected")
      or line:match("^%s*%(?%d+%s+row%(s%)%)%s*affected")
      or line:match("^%d+ rows? in set")
      or line:match("^%s*%(?%d+%s+rows? returned")
    then
      if #current_set > 0 then
        result_sets[#result_sets + 1] = { lines = current_set, status = line }
        current_set = {}
        current_status = ""
        in_data = false
      end
      goto continue
    end

    -- Handle Query OK (UPDATE/DELETE/INSERT)
    if line:match("^Query OK") then
      if #current_set > 0 then
        result_sets[#result_sets + 1] = { lines = current_set, status = current_status }
        current_set = {}
      end
      local count = line:match("(%d+)%s+rows?%s+affected")
      if count then
        local word = count == "1" and "row" or "rows"
        current_status = "(" .. count .. " " .. word .. " affected)"
      else
        current_status = line
      end
      result_sets[#result_sets + 1] = { lines = {}, status = current_status }
      current_status = ""
      in_data = false
      goto continue
    end

    -- Handle MySQL "Rows matched" line
    if line:match("^Rows matched:") then
      local changed = line:match("Changed:%s*(%d+)")
      if changed then
        local word = changed == "1" and "row" or "rows"
        current_status = "(" .. changed .. " " .. word .. " affected)"
        result_sets[#result_sets + 1] = { lines = {}, status = current_status }
        current_status = ""
      end
      goto continue
    end

    -- Detect MySQL table boundaries: two consecutive +----+ border lines
    local is_mysql_border = line:match("^%+[-+]+%+%s*$") ~= nil
    if is_mysql_border and #current_set >= 4 then
      local prev_line = current_set[#current_set]
      if prev_line:match("^%+[-+]+%+%s*$") then
        -- Remove the previous border (bottom of last table)
        table.remove(current_set)
        if #current_set > 0 then
          result_sets[#result_sets + 1] = { lines = current_set, status = current_status }
          current_status = ""
        end
        -- Start new set with this border as the top
        current_set = { line }
        in_data = true
        goto continue
      end
    end

    -- Skip mysql/mariadb warning lines between result sets
    if not in_data then
      if
        line:match("^mysql:")
        or line:match("^mariadb:")
        or line:match("^/.+/mysql:")
        or line:match("^/.+/mariadb:")
        or line:match("Deprecated program name")
        or vim.trim(line) == ""
      then
        goto continue
      end
    end

    -- Start collecting data
    if vim.trim(line) ~= "" then
      in_data = true
    end

    current_set[#current_set + 1] = line
    ::continue::
  end

  -- Don't forget the last result set
  if #current_set > 0 then
    result_sets[#result_sets + 1] = { lines = current_set, status = current_status }
  end

  -- Fallback: warnings-only output
  if #result_sets == 0 and #lines > 0 then
    local has_warning = false
    local only_warnings = true
    for _, line in ipairs(lines) do
      local trimmed = vim.trim(line)
      if trimmed ~= "" then
        if trimmed:match("^mysql:.*%[Warning%]") or trimmed:match("^/.+/mysql:") or trimmed:match("^/.+/mariadb:") or trimmed:match("Deprecated program name") then
          has_warning = true
        else
          only_warnings = false
          break
        end
      end
    end
    if only_warnings and has_warning then
      result_sets[#result_sets + 1] = { lines = {}, status = "Query OK" }
    end
  end

  return result_sets
end

-- ============================================================================
-- COLUMN ANALYSIS
-- ============================================================================

local function detect_column_type(_, rows, col_idx)
  local guid_count = 0
  local timestamp_count = 0
  local json_count = 0
  local number_count = 0
  local total_non_null = 0

  for _, row in ipairs(rows) do
    if col_idx > #row then
      goto continue
    end
    local val = row[col_idx]

    -- Skip NULL values
    if val == "NULL" or vim.trim(val) == "" then
      goto continue
    end
    total_non_null = total_non_null + 1

    -- GUID pattern
    if val:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      guid_count = guid_count + 1
    end

    -- Timestamp pattern: YYYY-MM-DD HH:MM:SS or YYYY-MM-DDTHH:MM:SS
    if val:match("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d") then
      timestamp_count = timestamp_count + 1
    end

    -- Number pattern: integer or decimal, optionally negative
    if val:match("^%-?%d+%.?%d*$") then
      number_count = number_count + 1
    end

    -- JSON pattern: starts with [ or {
    if val:match("^%s*[%[{]") then
      json_count = json_count + 1
    end

    ::continue::
  end

  -- Any GUID match makes entire column GUID
  if guid_count > 0 then
    return "guid"
  end

  -- Other types require majority match (>=50%)
  if total_non_null > 0 then
    if timestamp_count * 2 >= total_non_null then
      return "timestamp"
    end
    if number_count * 2 >= total_non_null then
      return "number"
    end
    if json_count * 2 >= total_non_null then
      return "json"
    end
  end

  return "default"
end

local function analyze_columns(headers, rows)
  local info = { types = {}, widths = {} }
  local max_widths = vim.g.dadbod_format_max_widths or M.max_widths

  for i = 1, #headers do
    local col_type = detect_column_type(headers[i], rows, i)
    info.types[i] = col_type

    local cap = max_widths[col_type] or max_widths["default"] or 40
    local actual_max = displaywidth(headers[i])

    for _, row in ipairs(rows) do
      if i <= #row then
        actual_max = math.max(actual_max, displaywidth(row[i]))
      end
    end

    local header_width = displaywidth(headers[i])
    local data_width = math.min(actual_max, cap)
    info.widths[i] = math.max(header_width, data_width)
  end

  return info
end

-- ============================================================================
-- TRUNCATION
-- ============================================================================

local function truncate_value(val, max_width, col_type)
  if displaywidth(val) <= max_width then
    return val
  end

  -- GUIDs: keep first 6 and last 6 chars
  if col_type == "guid" and max_width >= 15 then
    local prefix = val:sub(1, 6)
    local suffix = val:sub(-6)
    return prefix .. "..." .. suffix
  end

  -- Default: truncate end with ellipsis
  -- Use vim.fn.strcharpart for multi-byte safety
  local truncated = vim.fn.strpart(val, 0, max_width - 3)
  return truncated .. "..."
end

local function truncate_data_with_offset(headers, rows, col_info, row_offset)
  local result = { headers = {}, rows = {} }
  local max_widths = vim.g.dadbod_format_max_widths or M.max_widths

  -- Headers are never truncated
  for i, h in ipairs(headers) do
    result.headers[i] = h
  end

  local row_num = row_offset
  for _, row in ipairs(rows) do
    local new_row = {}
    for i, val in ipairs(row) do
      local max_w = col_info.widths[i] or max_widths["default"] or 40
      local col_type = col_info.types[i] or "default"

      -- Store original if truncated
      if displaywidth(val) > max_w then
        local key = row_num .. ":" .. (i - 1)
        vim.b.dbout_cell_data[key] = val
      end

      new_row[i] = truncate_value(val, max_w, col_type)
    end
    result.rows[#result.rows + 1] = new_row
    row_num = row_num + 1
  end

  return result
end

-- ============================================================================
-- TABLE RENDERING
-- ============================================================================

local function pad_value(val, width)
  local len = displaywidth(val)
  if len >= width then
    return val
  end
  return val .. string.rep(" ", width - len)
end

local function make_border_line(position, widths)
  local left, mid, right
  if position == "top" then
    left, mid, right = box.tl, box.tm, box.tr
  elseif position == "middle" then
    left, mid, right = box.lm, box.mm, box.rm
  else
    left, mid, right = box.bl, box.bm, box.br
  end

  local parts = {}
  for i, w in ipairs(widths) do
    parts[i] = string.rep(box.h, w + 2)
  end
  return left .. table.concat(parts, mid) .. right
end

local function make_data_line(values, widths)
  local parts = {}
  for i, w in ipairs(widths) do
    local val = values[i] or ""
    parts[i] = " " .. pad_value(val, w) .. " "
  end
  return box.v .. table.concat(parts, box.v) .. box.v
end

local function render_table(headers, rows, widths)
  local lines = {}
  lines[#lines + 1] = make_border_line("top", widths)
  lines[#lines + 1] = make_data_line(headers, widths)
  lines[#lines + 1] = make_border_line("middle", widths)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = make_data_line(row, widths)
  end
  lines[#lines + 1] = make_border_line("bottom", widths)
  return lines
end

-- ============================================================================
-- SYNTAX HIGHLIGHTING
-- ============================================================================

-- Compute byte offsets for each cell in a data line given column widths
-- Returns list of {start_byte, end_byte} for the value content area of each cell
local function compute_cell_byte_offsets(widths)
  local offsets = {}
  local pos = 3 + 1 -- skip first │ (3 bytes) + space (1 byte)
  for i, w in ipairs(widths) do
    offsets[i] = { start = pos, stop = pos + w }
    -- Move past: value (w bytes) + space (1) + │ (3) + space (1)
    pos = pos + w + 1 + 3 + 1
  end
  return offsets
end

local function apply_highlighting()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Clear all extmarks in our namespace
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Also clear any leftover matchadd IDs
  local old_ids = vim.w.dbout_match_ids
  if old_ids then
    for _, id in ipairs(old_ids) do
      pcall(vim.fn.matchdelete, id)
    end
  end
  vim.w.dbout_match_ids = {}

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Highlight borders and structure lines using extmarks
  for i, line in ipairs(lines) do
    local lnum = i - 1 -- 0-indexed

    -- Row count header lines: [TableName] (N rows) or standalone (N rows)
    if line:match("^%[.+%]%s+%(") or line:match("^%(%d+ rows?") or line:match("^Query OK") then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
        end_col = #line,
        hl_group = "DboutRowCount",
      })
      goto continue_line
    end

    -- Border lines (┌┐└┘├┤)
    if line:find("^\xe2\x94\x8c") or line:find("^\xe2\x94\x94") or line:find("^\xe2\x94\x9c") then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
        end_col = #line,
        hl_group = "DboutBorder",
      })
      goto continue_line
    end

    -- Header rows: │...│ line following a ┌...┐ line
    if i >= 2 and lines[i - 1]:find("^\xe2\x94\x8c") and line:find("^\xe2\x94\x82") then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
        end_col = #line,
        hl_group = "DboutHeader",
      })
      goto continue_line
    end

    ::continue_line::
  end

  -- Apply column-type highlighting using extmarks with byte offsets
  local col_info_list = vim.b.dbout_col_info_list
  local table_data_lines = vim.b.dbout_table_data_lines
  if not col_info_list or not table_data_lines then
    return
  end

  for table_idx = 1, #col_info_list do
    local col_info = col_info_list[table_idx]
    if table_idx > #table_data_lines then
      goto continue_table
    end
    local data_start = table_data_lines[table_idx][1]
    local data_end = table_data_lines[table_idx][2]
    local cell_offsets = compute_cell_byte_offsets(col_info.widths)

    for lnum_1 = data_start, data_end do
      local lnum = lnum_1 - 1 -- 0-indexed
      if lnum >= #lines then
        break
      end
      local line = lines[lnum_1]
      if not line then
        goto continue_row
      end

      for col_idx = 1, #col_info.types do
        local col_type = col_info.types[col_idx]
        if not cell_offsets[col_idx] then
          goto continue_col
        end

        local cell_start = cell_offsets[col_idx].start
        local cell_end = cell_offsets[col_idx].stop

        -- Bounds check
        if cell_start > #line then
          goto continue_col
        end
        local actual_end = math.min(cell_end, #line)

        -- Extract the cell content and find the non-whitespace value
        local cell_content = line:sub(cell_start + 1, actual_end)
        local val_start_offset, val_end_offset = cell_content:find("%S.*%S")
        if not val_start_offset then
          -- Try single non-whitespace char
          val_start_offset, val_end_offset = cell_content:find("%S")
        end
        if not val_start_offset then
          goto continue_col
        end

        local abs_start = cell_start + val_start_offset - 1
        local abs_end = cell_start + val_end_offset

        -- Check for NULL - override type color
        local val_text = cell_content:sub(val_start_offset, val_end_offset)
        local hl_group
        if val_text == "NULL" then
          hl_group = "DboutNull"
        elseif val_text:find("%.%.%.$") then
          hl_group = "DboutTruncated"
        elseif col_type == "guid" then
          hl_group = "DboutGuid"
        elseif col_type == "timestamp" then
          hl_group = "DboutTimestamp"
        elseif col_type == "number" then
          hl_group = "DboutNumber"
        else
          hl_group = "DboutString"
        end

        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, lnum, abs_start, {
          end_col = abs_end,
          hl_group = hl_group,
        })

        ::continue_col::
      end
      ::continue_row::
    end
    ::continue_table::
  end
end

-- ============================================================================
-- CELL EXPANSION
-- ============================================================================

local function get_column_at_position(line, col_pos)
  -- Count │ characters before cursor position
  local substr = vim.fn.strpart(line, 0, col_pos)
  local count = 0
  local idx = 1
  local v_bytes = box.v -- │ is 3 bytes in UTF-8
  while true do
    local found = substr:find(v_bytes, idx, true)
    if not found then
      break
    end
    count = count + 1
    idx = found + #v_bytes
  end
  -- First │ is left border, so subtract 1
  return count - 1
end

local function open_expand_window(value, header)
  vim.cmd("botright 1new")
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.bo.buflisted = false
  vim.bo.modifiable = true

  -- Set buffer name
  local title = header == "" and "[Cell Value]" or ("[" .. header .. "]")
  pcall(vim.cmd, "file " .. vim.fn.fnameescape(title))

  -- Insert content
  local lines = vim.split(value, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)

  -- Detect JSON for syntax highlighting
  if value:match("^%s*[%[{]") then
    vim.bo.filetype = "json"
  end

  vim.bo.modifiable = false

  -- Map q and Esc to close
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = true, silent = true })

  -- Mark as expansion window
  vim.b.dbout_expand_window = 1
end

-- ============================================================================
-- FROZEN HEADER (sticky column headers)
-- ============================================================================

local frozen = {
  win = nil,
  buf = nil,
  augroup = nil,
  last_topline = -1,
  last_leftcol = -1,
}

local function close_frozen_header()
  if frozen.win and vim.api.nvim_win_is_valid(frozen.win) then
    vim.api.nvim_win_close(frozen.win, true)
  end
  frozen.win = nil
  frozen.last_topline = -1
  frozen.last_leftcol = -1
end

local function apply_frozen_highlights(bufnr, num_lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  local groups = { "DboutBorder", "DboutHeader", "DboutBorder" }
  for i = 0, math.min(num_lines - 1, 3) do
    local line = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
    if line and groups[i + 1] then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, i, 0, {
        end_col = #line,
        hl_group = groups[i + 1],
      })
    end
  end
end

local function update_frozen_header()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "dbout" or vim.b[bufnr].dbout_is_formatted ~= 1 then
    close_frozen_header()
    return
  end

  local topline = vim.fn.line("w0")
  local view = vim.fn.winsaveview()
  local leftcol = view.leftcol

  local topline_changed = topline ~= frozen.last_topline
  local leftcol_changed = leftcol ~= frozen.last_leftcol

  if not topline_changed and not leftcol_changed then
    return
  end

  -- Horizontal-only scroll: just sync the float's scroll position
  if not topline_changed and leftcol_changed then
    frozen.last_leftcol = leftcol
    if frozen.win and vim.api.nvim_win_is_valid(frozen.win) then
      vim.api.nvim_win_call(frozen.win, function()
        vim.fn.winrestview({ leftcol = leftcol })
      end)
    end
    return
  end

  frozen.last_topline = topline
  frozen.last_leftcol = leftcol

  local header_lines_list = vim.b[bufnr].dbout_header_lines
  local table_data_lines = vim.b[bufnr].dbout_table_data_lines
  if not header_lines_list or not table_data_lines or #header_lines_list == 0 then
    close_frozen_header()
    return
  end

  -- Find table whose header scrolled off but whose data is still visible
  local target = nil
  for i = #header_lines_list, 1, -1 do
    local h = header_lines_list[i]
    local data_end = table_data_lines[i] and table_data_lines[i][2] or 0
    -- Show as soon as top border (h-1) scrolls off; data extends to data_end+1 (bottom border)
    if (h - 1) < topline and (data_end + 1) >= topline then
      target = i
      break
    end
  end

  if not target then
    close_frozen_header()
    return
  end

  -- Get the 3 header lines: top border, header data, mid border
  local h = header_lines_list[target]
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local frozen_lines = {}
  for l = h - 1, h + 1 do
    if l >= 1 and l <= #all_lines then
      frozen_lines[#frozen_lines + 1] = all_lines[l]
    end
  end

  if #frozen_lines == 0 then
    close_frozen_header()
    return
  end

  local win = vim.api.nvim_get_current_win()
  local win_info = vim.fn.getwininfo(win)[1]
  local textoff = win_info and win_info.textoff or 0
  local width = vim.api.nvim_win_get_width(win) - textoff

  -- Create or reuse scratch buffer
  if not frozen.buf or not vim.api.nvim_buf_is_valid(frozen.buf) then
    frozen.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[frozen.buf].buftype = "nofile"
    vim.bo[frozen.buf].bufhidden = "hide"
    vim.bo[frozen.buf].swapfile = false
    vim.bo[frozen.buf].buflisted = false
  end

  vim.api.nvim_buf_set_lines(frozen.buf, 0, -1, false, frozen_lines)
  apply_frozen_highlights(frozen.buf, #frozen_lines)

  if frozen.win and vim.api.nvim_win_is_valid(frozen.win) then
    vim.api.nvim_win_set_config(frozen.win, {
      relative = "win",
      win = win,
      row = 0,
      col = textoff,
      width = width,
      height = #frozen_lines,
    })
    vim.api.nvim_win_set_buf(frozen.win, frozen.buf)
  else
    frozen.win = vim.api.nvim_open_win(frozen.buf, false, {
      relative = "win",
      win = win,
      row = 0,
      col = textoff,
      width = width,
      height = #frozen_lines,
      style = "minimal",
      focusable = false,
      zindex = 50,
    })
    vim.wo[frozen.win].cursorline = false
  end

  -- Sync horizontal scroll with parent window
  if leftcol > 0 then
    vim.api.nvim_win_call(frozen.win, function()
      vim.fn.winrestview({ leftcol = leftcol })
    end)
  end
end

function M.setup_frozen_headers(bufnr)
  if frozen.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, frozen.augroup)
  end
  frozen.augroup = vim.api.nvim_create_augroup("dbout_frozen_header", { clear = true })

  -- Check on cursor movement (with topline cache for fast early-exit)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = frozen.augroup,
    buffer = bufnr,
    callback = update_frozen_header,
  })

  -- Check on scroll (also handles window resize in Neovim 0.9+)
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = frozen.augroup,
    callback = function()
      if vim.api.nvim_get_current_buf() == bufnr then
        frozen.last_topline = -1 -- force re-check (width may have changed)
        frozen.last_leftcol = -1
        update_frozen_header()
      end
    end,
  })

  -- Hide when leaving dbout buffer
  vim.api.nvim_create_autocmd("BufLeave", {
    group = frozen.augroup,
    buffer = bufnr,
    callback = close_frozen_header,
  })

  -- Re-check when entering dbout buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = frozen.augroup,
    buffer = bufnr,
    callback = function()
      frozen.last_topline = -1
      frozen.last_leftcol = -1
      vim.schedule(update_frozen_header)
    end,
  })

  -- Full cleanup when buffer is wiped
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = frozen.augroup,
    buffer = bufnr,
    callback = function()
      close_frozen_header()
      if frozen.buf and vim.api.nvim_buf_is_valid(frozen.buf) then
        pcall(vim.api.nvim_buf_delete, frozen.buf, { force = true })
        frozen.buf = nil
      end
      if frozen.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, frozen.augroup)
        frozen.augroup = nil
      end
    end,
  })
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function M.format_from_anywhere()
  local current_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "dbout" then
      vim.api.nvim_set_current_win(win)
      M.format()
      vim.api.nvim_set_current_win(current_win)
      return
    end
  end
  vim.notify("No dbout window found")
end

function M.auto_format()
  -- Cancel any existing poll
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
  poll_count = 0
  last_line_count = 0
  stable_count = 0

  -- Reset formatted flag
  vim.b.dbout_is_formatted = 0

  -- Start polling every 200ms
  poll_timer = vim.uv.new_timer()
  poll_timer:start(
    200,
    200,
    vim.schedule_wrap(function()
      -- Guard against callbacks firing after timer was stopped
      if not poll_timer then
        return
      end

      poll_count = poll_count + 1

      -- Find dbout buffer
      local dbout_bufnr = nil
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "dbout" then
          dbout_bufnr = buf
          break
        end
      end

      if not dbout_bufnr then
        if poll_count >= poll_max and poll_timer then
          poll_timer:stop()
          poll_timer:close()
          poll_timer = nil
        end
        return
      end

      -- Check line count stability
      local lines = vim.api.nvim_buf_get_lines(dbout_bufnr, 0, -1, false)
      local line_count = #lines

      if line_count > 1 and line_count == last_line_count then
        stable_count = stable_count + 1
        if stable_count >= 3 then
          if poll_timer then
            poll_timer:stop()
            poll_timer:close()
            poll_timer = nil
          end
          M.format_from_anywhere()
          return
        end
      else
        stable_count = 0
      end

      last_line_count = line_count

      -- Timeout
      if poll_count >= poll_max and poll_timer then
        poll_timer:stop()
        poll_timer:close()
        poll_timer = nil
        vim.notify("Auto-format timeout - use <leader>dF manually")
      end
    end)
  )
end

function M.format()
  -- Only format dbout buffers
  if vim.bo.filetype ~= "dbout" then
    return
  end

  -- Skip if already formatted
  if vim.b.dbout_is_formatted == 1 then
    return
  end

  -- Get buffer content
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if #lines == 0 then
    return
  end

  -- Skip empty or whitespace-only buffers
  local has_content = false
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      has_content = true
      break
    end
  end
  if not has_content then
    return
  end

  -- Skip if already formatted (contains box-drawing chars or header line)
  local first_line = lines[1]
  if
    first_line:find("^[\xe2\x94\x8c\xe2\x94\x90\xe2\x94\x94\xe2\x94\x98\xe2\x94\x9c\xe2\x94\xa4\xe2\x94\xac\xe2\x94\xb4\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x82]")
    or first_line:match("^%[.+%]%s+%(")
  then
    return
  end

  -- Skip error messages
  if first_line:match("^[Mm]sg%s") or first_line:match("^ERROR") or first_line:match("^[Ee]rror:") or first_line:match("^failed") or first_line:match("^ORA%-") or first_line:match("^PLS%-") or first_line:match("^SP2%-") or first_line:match("^SQL Error") then
    return
  end
  local content = table.concat(lines, "\n")
  if content:match("Msg%s+%d+.*Level%s+%d+") then
    return
  end
  if content:match("ERROR%s+%d+%s+%(%d+%)") then
    return
  end
  if
    content:lower():find("incorrect syntax")
    or content:lower():find("syntax error")
    or content:lower():find("permission denied")
    or content:lower():find("access denied")
    or content:lower():find("connection refused")
    or content:lower():find("login failed")
  then
    return
  end

  -- Store raw content for toggle
  vim.b.dbout_raw_content = vim.deepcopy(lines)

  -- Initialize cell data storage
  vim.b.dbout_cell_data = {}
  vim.b.dbout_all_headers = {}
  vim.b.dbout_all_rows = {}
  vim.b.dbout_col_info_list = {}
  vim.b.dbout_table_data_lines = {}
  vim.b.dbout_header_lines = {}

  -- Split into multiple result sets
  local result_sets = split_result_sets(lines)
  local all_formatted = {}
  local global_row_offset = 0

  -- Extract table names from the SQL query
  local table_names = extract_table_names()
  local table_name_idx = 1

  for _, result_set in ipairs(result_sets) do
    local result_lines = result_set.lines
    local status_msg = result_set.status or ""

    -- Handle status-only results
    if #result_lines == 0 and status_msg ~= "" then
      if #all_formatted > 0 then
        all_formatted[#all_formatted + 1] = ""
      end
      all_formatted[#all_formatted + 1] = status_msg
      goto continue_set
    end

    -- Parse the output
    local parsed = parse_output(result_lines)
    if #parsed.headers == 0 or #parsed.rows == 0 then
      if status_msg ~= "" then
        if #all_formatted > 0 then
          all_formatted[#all_formatted + 1] = ""
        end
        all_formatted[#all_formatted + 1] = status_msg
      end
      goto continue_set
    end

    -- Check for ROW_COUNT() result
    if #parsed.headers == 1 and parsed.headers[1] == "rows_affected" and #parsed.rows == 1 then
      local count = parsed.rows[1][1]
      if #all_formatted > 0 then
        all_formatted[#all_formatted + 1] = ""
      end
      local word = count == "1" and "row" or "rows"
      all_formatted[#all_formatted + 1] = "(" .. count .. " " .. word .. " affected)"
      goto continue_set
    end

    -- Validate parsing result - skip if malformed
    local is_malformed = false
    for _, h in ipairs(parsed.headers) do
      if h:match("%+[-+]+") or h:match("^%s*|%s*$") then
        is_malformed = true
        break
      end
    end
    if not is_malformed and #parsed.rows > 0 then
      for _, cell in ipairs(parsed.rows[1]) do
        if cell:match("%+[-+]+") then
          is_malformed = true
          break
        end
      end
      if not is_malformed then
        local all_dashes = true
        for _, cell in ipairs(parsed.rows[1]) do
          if not cell:match("^%s*%-+%s*$") then
            all_dashes = false
            break
          end
        end
        if all_dashes then
          is_malformed = true
        end
      end
    end
    if is_malformed then
      goto continue_set
    end

    -- Store for cell expansion
    local all_headers = vim.b.dbout_all_headers
    all_headers[#all_headers + 1] = parsed.headers
    vim.b.dbout_all_headers = all_headers

    local all_rows = vim.b.dbout_all_rows
    all_rows[#all_rows + 1] = parsed.rows
    vim.b.dbout_all_rows = all_rows

    -- Analyze columns
    local col_info = analyze_columns(parsed.headers, parsed.rows)

    local col_info_list = vim.b.dbout_col_info_list
    col_info_list[#col_info_list + 1] = col_info
    vim.b.dbout_col_info_list = col_info_list

    -- Truncate data
    local truncated = truncate_data_with_offset(parsed.headers, parsed.rows, col_info, global_row_offset)

    -- Render bordered table
    local formatted = render_table(truncated.headers, truncated.rows, col_info.widths)

    -- Add blank line between tables
    if #all_formatted > 0 then
      all_formatted[#all_formatted + 1] = ""
    end

    -- Add row count header
    local row_count = #parsed.rows
    local row_word = row_count == 1 and "row" or "rows"
    local count_text = status_msg ~= "" and status_msg or ("(" .. row_count .. " " .. row_word .. ")")
    local tbl_name = table_name_idx <= #table_names and table_names[table_name_idx] or ""
    if tbl_name ~= "" then
      all_formatted[#all_formatted + 1] = "[" .. tbl_name .. "] " .. count_text
    else
      all_formatted[#all_formatted + 1] = count_text
    end
    table_name_idx = table_name_idx + 1

    -- Track header line number
    local table_start_line = #all_formatted + 1
    local header_line = table_start_line + 1
    local header_lines = vim.b.dbout_header_lines
    header_lines[#header_lines + 1] = header_line
    vim.b.dbout_header_lines = header_lines

    -- Track data line range
    local data_start = table_start_line + 3
    local data_end = table_start_line + 3 + #parsed.rows - 1
    local data_lines_list = vim.b.dbout_table_data_lines
    data_lines_list[#data_lines_list + 1] = { data_start, data_end }
    vim.b.dbout_table_data_lines = data_lines_list

    vim.list_extend(all_formatted, formatted)
    global_row_offset = global_row_offset + #parsed.rows

    ::continue_set::
  end

  if #all_formatted == 0 then
    return
  end

  -- Mark as formatted
  vim.b.dbout_is_formatted = 1

  -- For backwards compatibility
  local bh = vim.b.dbout_all_headers
  if bh and #bh > 0 then
    vim.b.dbout_headers = bh[1]
  end
  local br = vim.b.dbout_all_rows
  if br and #br > 0 then
    vim.b.dbout_parsed_rows = br[1]
  end

  -- Replace buffer content
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, all_formatted)
  vim.bo.modifiable = false
  vim.bo.modified = false
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  -- Apply syntax highlighting
  apply_highlighting()
end

function M.expand_cell()
  local cell_data = vim.b.dbout_cell_data
  if not cell_data then
    vim.notify("No formatted data available")
    return
  end

  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local col_pos = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Find which table and data row
  local data_row = -1
  local table_idx = -1
  local row_offset = 0
  local table_data_lines = vim.b.dbout_table_data_lines
  if table_data_lines then
    for i, range in ipairs(table_data_lines) do
      local start, stop = range[1], range[2]
      if line_num >= start and line_num <= stop then
        data_row = row_offset + (line_num - start)
        table_idx = i
        break
      end
      row_offset = row_offset + (stop - start + 1)
    end
  end

  if data_row < 0 then
    vim.notify("Not on a data row")
    return
  end

  -- Find column at cursor position
  local line = vim.api.nvim_get_current_line()
  local col_idx = get_column_at_position(line, col_pos)

  if col_idx < 0 then
    vim.notify("Not in a cell")
    return
  end

  -- Look up original value
  local key = data_row .. ":" .. col_idx
  local value

  if cell_data[key] then
    value = cell_data[key]
  elseif table_idx > 0 then
    local all_rows = vim.b.dbout_all_rows
    if all_rows and table_idx <= #all_rows then
      local local_row = line_num - table_data_lines[table_idx][1] + 1
      local rows = all_rows[table_idx]
      if local_row <= #rows and (col_idx + 1) <= #rows[local_row] then
        value = rows[local_row][col_idx + 1]
      end
    end
  end

  if not value then
    vim.notify("No data for this cell")
    return
  end

  -- Get column header
  local header = ""
  local all_headers = vim.b.dbout_all_headers
  if all_headers and table_idx > 0 and table_idx <= #all_headers then
    local headers = all_headers[table_idx]
    if (col_idx + 1) <= #headers then
      header = headers[col_idx + 1]
    end
  end

  open_expand_window(value, header)
end

function M.close_expand()
  -- If in expansion window, close it
  if vim.b.dbout_expand_window then
    vim.cmd("close")
    return
  end

  -- Look for expansion window in other windows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, is_expand = pcall(vim.api.nvim_buf_get_var, buf, "dbout_expand_window")
    if ok and is_expand then
      vim.api.nvim_win_close(win, true)
      return
    end
  end
end

function M.toggle_raw()
  local raw_content = vim.b.dbout_raw_content
  if not raw_content then
    vim.notify("No raw content stored")
    return
  end

  vim.bo.modifiable = true

  if vim.b.dbout_is_formatted == 1 then
    -- Switch to raw
    vim.api.nvim_buf_set_lines(0, 0, -1, false, raw_content)
    vim.b.dbout_is_formatted = 0
    vim.notify("Showing raw output")
  else
    -- Re-format
    vim.api.nvim_buf_set_lines(0, 0, -1, false, raw_content)
    vim.bo.modifiable = false
    M.format()
    vim.notify("Showing formatted output")
    return
  end

  vim.bo.modifiable = false
end

return M
