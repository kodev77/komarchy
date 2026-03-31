-- db2.lua - a neovim password manager (lua port)
--
-- usage: :Db2 or <leader>d2 to open, or :Db2 /path/to/data.json
--
-- keybindings:
--   j/k       move up/down
--   gg/G      top/bottom
--   Enter/l   select entry
--   h         back to list
--   y         yank password
--   Y         yank username
--   s         show/hide password
--   a         add new entry
--   A         add additional entry
--   dd        delete entry
--   e         edit field
--   /         search
--   Esc       clear search
--   q         close
--   ?         help

local M = {}

-- state
local state = {
  entries = {},
  current_entry = nil,
  current_entry_index = -1,
  list_bufnr = -1,
  detail_bufnr = -1,
  notes_expanded = false,
  additional_expanded = false,
  notes_line = 0,
  additional_line = 0,
  file_path = "",
  field_lines = {},
  additional_entry_lines = {},
  additional_field_lines = {},
  edit_additional_index = -1,
  show_password = false,
  search_active = false,
  filtered_entries = {},
  edit_bufnr = -1,
  edit_field = "",
}

-- default data path
local default_path = vim.fn.expand("~/Documents/db2.json")

--- Strip HTML tags and decode entities
local function clean_html(html)
  local text = html
  text = text:gsub("<br%s*/?>", "\n")
  text = text:gsub("<div>", "")
  text = text:gsub("</div>", "\n")
  text = text:gsub("<[^>]*>", "")
  text = text:gsub("&nbsp;", " ")
  text = text:gsub("&amp;", "&")
  text = text:gsub("&lt;", "<")
  text = text:gsub("&gt;", ">")
  return text
end

--- Copy text to clipboard
local function copy_to_clipboard(text)
  -- try vim clipboard register first
  if vim.fn.has("clipboard") == 1 then
    vim.fn.setreg("+", text)
    return true
  end
  -- try wl-copy (wayland)
  if vim.fn.executable("wl-copy") == 1 then
    vim.fn.system({ "wl-copy", "--" }, text)
    return vim.v.shell_error == 0
  end
  -- try xclip
  if vim.fn.executable("xclip") == 1 then
    vim.fn.system({ "xclip", "-selection", "clipboard" }, text)
    return vim.v.shell_error == 0
  end
  -- try xsel
  if vim.fn.executable("xsel") == 1 then
    vim.fn.system({ "xsel", "--clipboard", "--input" }, text)
    return vim.v.shell_error == 0
  end
  return false
end

--- Save entries to JSON file
local function save_db2()
  if state.file_path == "" then
    vim.notify("db2: no file path", vim.log.levels.ERROR)
    return
  end
  local ok, json = pcall(vim.json.encode, state.entries)
  if not ok then
    vim.notify("db2: failed to encode json", vim.log.levels.ERROR)
    return
  end
  -- pretty print: one entry per line
  json = json:gsub("%[{", "[\n  {")
  json = json:gsub("},{", "},\n  {")
  json = json:gsub("}]", "}\n]")
  local lines = vim.split(json, "\n")
  vim.fn.writefile(lines, state.file_path)
end

--- Render the detail pane for current entry
local function render_detail()
  local winid = vim.fn.bufwinid(state.detail_bufnr)
  if winid == -1 then
    return
  end

  local e = state.current_entry
  if not e then
    return
  end

  local pwd = e.password or ""
  local pwd_display
  if pwd == "" then
    pwd_display = "(none)"
  elseif state.show_password then
    pwd_display = pwd
  else
    pwd_display = string.rep("*", #pwd)
  end

  state.field_lines = {}
  local lines = {
    "═══════════════════════════════════════",
    " " .. (e.name or ""),
    "═══════════════════════════════════════",
    "",
  }

  state.field_lines["name"] = 2
  state.field_lines["url"] = #lines + 1
  lines[#lines + 1] = "  url:      " .. (e.url or "")
  state.field_lines["username"] = #lines + 1
  lines[#lines + 1] = "  username: " .. (e.username or "")
  state.field_lines["password"] = #lines + 1
  lines[#lines + 1] = "  password: " .. pwd_display
  state.field_lines["totp"] = #lines + 1
  local totp = e.totp or ""
  lines[#lines + 1] = "  totp:     " .. (totp == "" and "(none)" or totp)
  state.field_lines["groupings"] = #lines + 1
  lines[#lines + 1] = "  group:    " .. (e.groupings or "")
  state.field_lines["user"] = #lines + 1
  lines[#lines + 1] = "  owner:    " .. (e.user or "")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "───────────────────────────────────────"
  lines[#lines + 1] = "  [s] show/hide  [y] yank  [e] edit  [?] help"
  lines[#lines + 1] = "───────────────────────────────────────"

  -- notes section
  local extra = e.extra or ""
  local extra_lines = {}
  if extra ~= "" then
    extra_lines = vim.split(clean_html(extra), "\n")
  end
  local extra_count = #extra_lines
  lines[#lines + 1] = ""
  state.notes_line = #lines + 1
  if state.notes_expanded then
    lines[#lines + 1] = "[-] notes: (" .. extra_count .. " lines)"
    if #extra_lines == 0 then
      lines[#lines + 1] = "  (none)"
    else
      for _, line in ipairs(extra_lines) do
        lines[#lines + 1] = "  " .. line
      end
    end
  else
    lines[#lines + 1] = "[+] notes: (" .. extra_count .. " lines)"
  end

  -- additional entries section
  local additional = e.additionalEntries or {}
  lines[#lines + 1] = ""
  state.additional_line = #lines + 1
  state.additional_entry_lines = {}
  state.additional_field_lines = {}
  if state.additional_expanded then
    lines[#lines + 1] = "[-] additional entries: " .. #additional
    if #additional == 0 then
      lines[#lines + 1] = "  (none)"
    else
      for idx, entry in ipairs(additional) do
        lines[#lines + 1] = ""
        local entry_start = #lines + 1
        lines[#lines + 1] = "  " .. idx .. ". " .. (entry.name or "(unnamed)")
        state.additional_entry_lines[entry_start] = idx - 1
        state.additional_field_lines[entry_start] = "name"

        lines[#lines + 1] = "     url:  " .. (entry.url or "")
        state.additional_entry_lines[#lines] = idx - 1
        state.additional_field_lines[#lines] = "url"

        lines[#lines + 1] = "     user: " .. (entry.username or "")
        state.additional_entry_lines[#lines] = idx - 1
        state.additional_field_lines[#lines] = "username"

        local apwd = entry.password or ""
        local apwd_display
        if state.show_password then
          apwd_display = apwd
        else
          apwd_display = string.rep("*", #apwd)
        end
        lines[#lines + 1] = "     pass: " .. apwd_display
        state.additional_entry_lines[#lines] = idx - 1
        state.additional_field_lines[#lines] = "password"

        if (entry.extra or "") ~= "" then
          lines[#lines + 1] = "     note: " .. entry.extra
          state.additional_entry_lines[#lines] = idx - 1
          state.additional_field_lines[#lines] = "extra"
        end
      end
    end
  else
    lines[#lines + 1] = "[+] additional entries: " .. #additional
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.detail_bufnr })
  vim.api.nvim_buf_set_lines(state.detail_bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.detail_bufnr })
end

--- Populate the list pane
local function populate_list(entries)
  entries = entries or state.entries
  local winid = vim.fn.bufwinid(state.list_bufnr)
  if winid == -1 then
    return
  end

  local lines = {}
  for _, entry in ipairs(entries) do
    local additional = entry.additionalEntries or {}
    local marker = #additional > 0 and "+" or " "
    lines[#lines + 1] = marker .. " " .. (entry.name or "(unnamed)")
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.list_bufnr })
  vim.api.nvim_buf_set_lines(state.list_bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.list_bufnr })
end

--- Close db2 buffers
local function close_db2()
  if state.list_bufnr ~= -1 and vim.api.nvim_buf_is_valid(state.list_bufnr) then
    vim.api.nvim_buf_delete(state.list_bufnr, { force = true })
  end
  if state.detail_bufnr ~= -1 and vim.api.nvim_buf_is_valid(state.detail_bufnr) then
    vim.api.nvim_buf_delete(state.detail_bufnr, { force = true })
  end
  state.list_bufnr = -1
  state.detail_bufnr = -1
  state.current_entry = nil
end

--- Yank password to clipboard
local function yank_password()
  if not state.current_entry then
    return
  end
  local pwd = state.current_entry.password or ""
  if pwd == "" then
    vim.notify("db2: no password")
    return
  end
  if copy_to_clipboard(pwd) then
    vim.notify("db2: password copied to clipboard")
  else
    vim.fn.setreg('"', pwd)
    vim.notify("db2: password yanked to register")
  end
end

--- Yank username to clipboard
local function yank_username()
  if not state.current_entry then
    return
  end
  local user = state.current_entry.username or ""
  if user == "" then
    vim.notify("db2: no username")
    return
  end
  if copy_to_clipboard(user) then
    vim.notify("db2: username copied to clipboard")
  else
    vim.fn.setreg('"', user)
    vim.notify("db2: username yanked to register")
  end
end

--- Toggle password visibility
local function toggle_password()
  local pos = vim.api.nvim_win_get_cursor(0)
  state.show_password = not state.show_password
  render_detail()
  -- restore cursor if in detail pane
  local winid = vim.fn.bufwinid(state.detail_bufnr)
  if winid ~= -1 and vim.api.nvim_get_current_win() == winid then
    pcall(vim.api.nvim_win_set_cursor, winid, pos)
  end
end

--- Toggle notes or additional entries section
local function toggle_section()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if lnum == state.notes_line then
    state.notes_expanded = not state.notes_expanded
    render_detail()
    pcall(vim.api.nvim_win_set_cursor, 0, { state.notes_line, 0 })
  elseif lnum == state.additional_line then
    state.additional_expanded = not state.additional_expanded
    render_detail()
    pcall(vim.api.nvim_win_set_cursor, 0, { state.additional_line, 0 })
  end
end

--- Cancel edit
local function cancel_edit()
  if state.edit_bufnr ~= -1 and vim.api.nvim_buf_is_valid(state.edit_bufnr) then
    vim.api.nvim_buf_delete(state.edit_bufnr, { force = true })
  end
  state.edit_bufnr = -1
  vim.notify("db2: edit cancelled")
end

--- Save edited field
local function save_field()
  if state.edit_bufnr == -1 or not vim.api.nvim_buf_is_valid(state.edit_bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(state.edit_bufnr, 0, -1, false)
  local value = table.concat(lines, "\n")

  if state.edit_additional_index >= 0 then
    -- editing additional entry field
    local additional = state.current_entry.additionalEntries or {}
    local idx = state.edit_additional_index + 1 -- lua 1-indexed
    if idx >= 1 and idx <= #additional then
      additional[idx][state.edit_field] = value
      state.current_entry.additionalEntries = additional
      if state.current_entry_index >= 0 then
        state.entries[state.current_entry_index + 1].additionalEntries = additional
      end
    end
  else
    -- editing main entry field
    state.current_entry[state.edit_field] = value
    if state.current_entry_index >= 0 then
      state.entries[state.current_entry_index + 1][state.edit_field] = value
    end
  end

  save_db2()

  -- close edit buffer
  vim.api.nvim_buf_delete(state.edit_bufnr, { force = true })
  state.edit_bufnr = -1

  render_detail()

  -- update list if name changed
  if state.edit_field == "name" and state.edit_additional_index < 0 then
    populate_list()
  end

  vim.notify("db2: saved " .. state.edit_field)
end

--- Open edit buffer for a field
local function open_edit_buffer(field_key, value, label)
  vim.cmd("belowright new")
  state.edit_bufnr = vim.api.nvim_get_current_buf()
  state.edit_field = field_key

  vim.bo.buftype = "acwrite"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.bo.filetype = "db2-edit"

  vim.api.nvim_buf_set_name(state.edit_bufnr, "[Db2-Edit:" .. label .. "]")

  -- set content
  if value == "" then
    vim.api.nvim_buf_set_lines(state.edit_bufnr, 0, -1, false, { "" })
  else
    vim.api.nvim_buf_set_lines(state.edit_bufnr, 0, -1, false, vim.split(value, "\n"))
  end

  -- keybindings
  vim.keymap.set("n", "q", cancel_edit, { buffer = state.edit_bufnr })
  vim.keymap.set("n", "<Esc>", cancel_edit, { buffer = state.edit_bufnr })

  -- save on :w
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = state.edit_bufnr,
    callback = save_field,
  })

  vim.notify("db2: editing " .. label .. " (q to cancel, :w to save)")
end

--- Edit the field under cursor
local function edit_field()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  -- check if on additional entry line
  if state.additional_entry_lines[lnum] ~= nil then
    local add_idx = state.additional_entry_lines[lnum]
    local add_field = state.additional_field_lines[lnum] or ""
    if add_field ~= "" then
      local additional = state.current_entry.additionalEntries or {}
      local entry = additional[add_idx + 1]
      if entry then
        local value = entry[add_field] or ""
        local entry_name = entry.name or "(unnamed)"
        state.edit_additional_index = add_idx
        open_edit_buffer(add_field, value, entry_name .. ":" .. add_field)
      end
      return
    end
  end

  -- find which main field we're on
  local field_key = nil
  for key, line in pairs(state.field_lines) do
    if lnum == line then
      field_key = key
      break
    end
  end

  -- check if on notes line
  if lnum == state.notes_line then
    field_key = "extra"
  end

  if not field_key then
    vim.notify("db2: not on an editable field")
    return
  end

  local value = state.current_entry[field_key] or ""
  if field_key == "extra" then
    value = clean_html(value)
  end

  state.edit_additional_index = -1
  open_edit_buffer(field_key, value, field_key)
end

--- Delete the currently selected additional entry
local function delete_additional_entry(index)
  local additional = state.current_entry.additionalEntries or {}
  if index < 0 or index >= #additional then
    vim.notify("db2: invalid additional entry")
    return
  end

  local name = additional[index + 1].name or "(unnamed)"
  vim.ui.input({ prompt = 'delete additional "' .. name .. '"? (y/n): ' }, function(input)
    if not input or input:lower() ~= "y" then
      vim.notify("cancelled")
      return
    end

    table.remove(additional, index + 1)
    state.current_entry.additionalEntries = additional
    if state.current_entry_index >= 0 then
      state.entries[state.current_entry_index + 1].additionalEntries = additional
    end

    save_db2()
    render_detail()
    populate_list()
    vim.notify('db2: deleted additional entry "' .. name .. '"')
  end)
end

--- Delete the current entry (or additional entry if cursor is on one)
local function delete_entry()
  if not state.current_entry then
    vim.notify("db2: no entry selected")
    return
  end

  -- check if on an additional entry line
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if state.additional_entry_lines[lnum] ~= nil then
    delete_additional_entry(state.additional_entry_lines[lnum])
    return
  end

  local name = state.current_entry.name or "(unnamed)"
  vim.ui.input({ prompt = 'delete "' .. name .. '"? (y/n): ' }, function(input)
    if not input or input:lower() ~= "y" then
      vim.notify("cancelled")
      return
    end

    if state.current_entry_index >= 0 then
      table.remove(state.entries, state.current_entry_index + 1)
    end

    save_db2()
    populate_list()

    -- select next entry or previous if at end
    local new_index = state.current_entry_index
    if new_index >= #state.entries then
      new_index = #state.entries - 1
    end

    if new_index >= 0 and #state.entries > 0 then
      state.current_entry = state.entries[new_index + 1]
      state.current_entry_index = new_index
      render_detail()
      local winid = vim.fn.bufwinid(state.list_bufnr)
      if winid ~= -1 then
        vim.api.nvim_win_set_cursor(winid, { new_index + 1, 0 })
      end
    else
      state.current_entry = nil
      state.current_entry_index = -1
      render_detail()
    end

    vim.notify('db2: deleted "' .. name .. '"')
  end)
end

--- Add a new entry
local function add_entry()
  vim.ui.input({ prompt = "name: " }, function(name)
    if not name or name == "" then
      vim.notify("cancelled")
      return
    end

    local new_entry = {
      id = tostring(#state.entries + 1),
      name = name,
      url = "",
      username = "",
      password = "",
      totp = "",
      extra = "",
      groupings = "Passwords",
      fav = "0.00",
      user = "",
      additionalEntries = {},
    }

    state.entries[#state.entries + 1] = new_entry
    save_db2()
    populate_list()

    state.current_entry = new_entry
    state.current_entry_index = #state.entries - 1
    state.show_password = false
    state.notes_expanded = false
    state.additional_expanded = false
    render_detail()

    local winid = vim.fn.bufwinid(state.list_bufnr)
    if winid ~= -1 then
      vim.api.nvim_win_set_cursor(winid, { #state.entries, 0 })
    end

    vim.notify('db2: created "' .. name .. '"')
  end)
end

--- Add an additional entry to the current entry
local function add_additional_entry()
  if not state.current_entry then
    vim.notify("db2: no entry selected")
    return
  end

  vim.ui.input({ prompt = "additional entry name: " }, function(name)
    if not name or name == "" then
      vim.notify("cancelled")
      return
    end

    local additional = state.current_entry.additionalEntries or {}
    local new_additional = {
      ID = tostring(#additional + 1),
      name = name,
      url = "",
      username = "",
      password = "",
      extra = "",
    }

    additional[#additional + 1] = new_additional
    state.current_entry.additionalEntries = additional
    if state.current_entry_index >= 0 then
      state.entries[state.current_entry_index + 1].additionalEntries = additional
    end

    save_db2()
    state.additional_expanded = true
    render_detail()
    populate_list()

    vim.notify('db2: added additional entry "' .. name .. '"')
  end)
end

--- Search entries
local function search_db2()
  vim.ui.input({ prompt = "search: " }, function(term)
    if not term or term == "" then
      return
    end

    local term_lower = term:lower()
    local matches = {}

    for _, entry in ipairs(state.entries) do
      local hit = false
      if (entry.name or ""):lower():find(term_lower, 1, true) then
        hit = true
      elseif (entry.url or ""):lower():find(term_lower, 1, true) then
        hit = true
      elseif (entry.username or ""):lower():find(term_lower, 1, true) then
        hit = true
      elseif (entry.extra or ""):lower():find(term_lower, 1, true) then
        hit = true
      end
      if hit then
        matches[#matches + 1] = entry
      end
    end

    if #matches == 0 then
      vim.notify("db2: no matches")
      return
    end

    state.filtered_entries = matches
    state.search_active = true
    populate_list(matches)

    -- update buffer name to show count
    local winid = vim.fn.bufwinid(state.list_bufnr)
    if winid ~= -1 then
      pcall(vim.api.nvim_buf_set_name, state.list_bufnr, "[Db2:" .. #matches .. "/" .. #state.entries .. "]")
    end

    vim.notify("db2: " .. #matches .. " matches")
  end)
end

--- Clear search and restore full list
local function clear_search()
  if state.search_active then
    state.search_active = false
    populate_list()
    pcall(vim.api.nvim_buf_set_name, state.list_bufnr, "[Db2]")
    vim.notify("db2: search cleared")
  end
end

--- Show entry detail from list
local function show_entry_detail()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entries = state.search_active and state.filtered_entries or state.entries

  if lnum < 1 or lnum > #entries then
    return
  end

  state.current_entry = entries[lnum]
  -- find actual index in main entries
  for i, e in ipairs(state.entries) do
    if e == state.current_entry then
      state.current_entry_index = i - 1
      break
    end
  end

  state.show_password = false
  state.notes_expanded = false
  state.additional_expanded = false
  render_detail()

  -- move to detail pane
  local winid = vim.fn.bufwinid(state.detail_bufnr)
  if winid ~= -1 then
    vim.api.nvim_set_current_win(winid)
  end
end

--- Auto-preview: update detail when moving cursor in list
local function on_cursor_moved_list()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entries = state.search_active and state.filtered_entries or state.entries

  if lnum < 1 or lnum > #entries then
    return
  end

  local entry = entries[lnum]
  if entry ~= state.current_entry then
    state.current_entry = entry
    for i, e in ipairs(state.entries) do
      if e == entry then
        state.current_entry_index = i - 1
        break
      end
    end
    state.show_password = false
    state.notes_expanded = false
    state.additional_expanded = false
    render_detail()
  end
end

--- Show help popup
local function show_help()
  local lines = {
    "db2 keybindings:",
    "",
    "  j/k     move up/down",
    "  gg/G    top/bottom",
    "  Enter/l select entry",
    "  h       back to list",
    "",
    "  y       yank password",
    "  Y       yank username",
    "  s       show/hide password",
    "",
    "  a       add new entry",
    "  A       add additional entry (in detail)",
    "  dd      delete entry",
    "  e       edit field (on field line)",
    "  Enter   expand/collapse section (in detail)",
    "",
    "  /       search",
    "  Esc     clear search",
    "  q       close db2",
    "  ?       this help",
  }

  local width = 52
  local height = math.min(#lines, 20)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Help ",
  })

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf })
end

--- Setup keymaps for the list buffer
local function setup_list_buffer()
  local buf = state.list_bufnr
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "db2-list"

  pcall(vim.api.nvim_buf_set_name, buf, "[Db2]")

  local winid = vim.fn.bufwinid(buf)
  if winid ~= -1 then
    vim.wo[winid].wrap = false
    vim.wo[winid].cursorline = true
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<CR>", show_entry_detail, opts)
  vim.keymap.set("n", "l", show_entry_detail, opts)
  vim.keymap.set("n", "q", close_db2, opts)
  vim.keymap.set("n", "y", yank_password, opts)
  vim.keymap.set("n", "Y", yank_username, opts)
  vim.keymap.set("n", "s", toggle_password, opts)
  vim.keymap.set("n", "/", search_db2, opts)
  vim.keymap.set("n", "<Esc>", clear_search, opts)
  vim.keymap.set("n", "?", show_help, opts)
  vim.keymap.set("n", "a", add_entry, opts)
  vim.keymap.set("n", "dd", delete_entry, opts)

  -- auto-preview on cursor move
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = on_cursor_moved_list,
  })
end

--- Setup keymaps for the detail buffer
local function setup_detail_buffer()
  local buf = state.detail_bufnr
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "db2-detail"

  pcall(vim.api.nvim_buf_set_name, buf, "[Db2-Detail]")

  local winid = vim.fn.bufwinid(buf)
  if winid ~= -1 then
    vim.wo[winid].wrap = false
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", close_db2, opts)
  vim.keymap.set("n", "h", "<cmd>wincmd h<CR>", opts)
  vim.keymap.set("n", "y", yank_password, opts)
  vim.keymap.set("n", "Y", yank_username, opts)
  vim.keymap.set("n", "s", toggle_password, opts)
  vim.keymap.set("n", "?", show_help, opts)
  vim.keymap.set("n", "<CR>", toggle_section, opts)
  vim.keymap.set("n", "e", edit_field, opts)
  vim.keymap.set("n", "a", add_entry, opts)
  vim.keymap.set("n", "A", add_additional_entry, opts)
  vim.keymap.set("n", "dd", delete_entry, opts)
end

--- Create the split layout
local function create_layout()
  close_db2()

  -- list buffer on the left
  vim.cmd("enew")
  state.list_bufnr = vim.api.nvim_get_current_buf()
  setup_list_buffer()

  -- detail buffer on the right
  vim.cmd("vnew")
  state.detail_bufnr = vim.api.nvim_get_current_buf()
  setup_detail_buffer()

  -- go back to list and resize
  vim.cmd("wincmd h")
  vim.cmd("vertical resize 40")

  -- populate and show first entry
  populate_list()

  if #state.entries > 0 then
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.current_entry = state.entries[1]
    state.current_entry_index = 0
    state.show_password = false
    state.notes_expanded = false
    state.additional_expanded = false
    render_detail()
  end
end

--- Main entry point
function M.open(path)
  path = (path and path ~= "") and path or (vim.g.db2_path or default_path)
  path = vim.fn.expand(path)

  if vim.fn.filereadable(path) == 0 then
    vim.notify("db2: file not found: " .. path, vim.log.levels.ERROR)
    return
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    vim.notify("db2: failed to parse json", vim.log.levels.ERROR)
    return
  end

  state.entries = data
  state.file_path = path
  create_layout()
end

return M
