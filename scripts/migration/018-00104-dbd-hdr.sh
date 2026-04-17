#!/usr/bin/env bash
# dadbod: header-row │ chrome uses DboutBorder (column name text keeps DboutHeader)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if grep -q "Header row . chrome" "$FORMAT"; then
  echo "  already patched, skipping"
  exit 0
fi

echo "patching header-row vertical bars to use DboutBorder..."

INSERT_FILE=$(mktemp)
cat > "$INSERT_FILE" << 'LUAEOF'
    -- Header row │ chrome: override to DboutBorder so column name text stays DboutHeader but bars match borders
    local header_line = vim.b.dbout_header_lines and vim.b.dbout_header_lines[table_idx]
    if header_line then
      local hlnum = header_line - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, hlnum, 0, { end_col = 3, hl_group = "DboutBorder" })
      for ci = 1, #col_info.widths do
        local off = cell_offsets[ci]
        if off then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, hlnum, off.stop + 1, { end_col = off.stop + 4, hl_group = "DboutBorder" })
        end
      end
    end
LUAEOF

# Append after the cell_offsets assignment inside the per-table loop
sed -i '/local cell_offsets = compute_cell_byte_offsets(col_info.widths)/{
  r '"$INSERT_FILE"'
}' "$FORMAT"

rm -f "$INSERT_FILE"

echo "  util/dadbod-format.lua: header-row │ chrome uses DboutBorder"
