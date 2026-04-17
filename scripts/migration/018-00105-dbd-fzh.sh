#!/usr/bin/env bash
# dadbod: frozen/sticky header │ chrome uses DboutBorder (column name text keeps DboutHeader)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
FORMAT="$NVIM_DIR/lua/util/dadbod-format.lua"

if [[ ! -f "$FORMAT" ]]; then
  echo "dadbod-format.lua not found, skipping"
  exit 0
fi

if grep -q "Overlay DboutBorder on each" "$FORMAT"; then
  echo "  already patched, skipping"
  exit 0
fi

echo "patching frozen-header vertical bars to use DboutBorder..."

INSERT_FILE=$(mktemp)
cat > "$INSERT_FILE" << 'LUAEOF'
      -- Overlay DboutBorder on each │ so column names stay DboutHeader but bars match borders
      if groups[i + 1] == "DboutHeader" then
        local pos = 1
        while true do
          local s, e = line:find("\xe2\x94\x82", pos, true)
          if not s then break end
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i, s - 1, { end_col = e, hl_group = "DboutBorder" })
          pos = e + 1
        end
      end
LUAEOF

# Within apply_frozen_highlights, append after the `})` that closes the extmark call
sed -i '/apply_frozen_highlights/,/^end$/{
  /^      })$/r '"$INSERT_FILE"'
}' "$FORMAT"

rm -f "$INSERT_FILE"

echo "  util/dadbod-format.lua: frozen-header │ chrome uses DboutBorder"
