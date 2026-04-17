#!/usr/bin/env bash
# dadbod: data-row vertical │ separators use DboutBorder to match the table chrome
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if grep -q -- "-- Data rows: " "$FORMAT"; then
  echo "  already patched, skipping"
  exit 0
fi

echo "patching data-row vertical bars to use DboutBorder..."

INSERT_FILE=$(mktemp)
cat > "$INSERT_FILE" << 'LUAEOF'
    -- Data rows: non-header │...│ lines → DboutBorder chrome; cell content overridden by per-cell extmarks later
    if line:find("^\xe2\x94\x82") then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum, 0, {
        end_col = #line,
        hl_group = "DboutBorder",
      })
      goto continue_line
    end
LUAEOF

# Append the block after the `    end` that closes the Header rows if, limited to that range
sed -i '/-- Header rows: /,/^    end$/{
  /^    end$/r '"$INSERT_FILE"'
}' "$FORMAT"

rm -f "$INSERT_FILE"

echo "  util/dadbod-format.lua: data-row │ chrome uses DboutBorder"
