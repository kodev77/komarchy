#!/usr/bin/env bash
# neovim: disable markdownlint diagnostics
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/disable-markdownlint.lua"

if [[ -f "$PLUGIN" ]]; then
  echo "  disable-markdownlint.lua already exists, skipping"
  exit 0
fi

cat > "$PLUGIN" << 'LUAEOF'
-- komarchy: disable markdownlint-cli2 diagnostics
return {
	"mfussenegger/nvim-lint",
	opts = function(_, opts)
		opts.linters_by_ft = opts.linters_by_ft or {}
		opts.linters_by_ft.markdown = {}
		opts.linters_by_ft["markdown.mdx"] = {}
	end,
}
LUAEOF
echo "  wrote $PLUGIN"
