#!/usr/bin/env bash
# neovim: neovim diffview plugin with git diff keybindings
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing diffview plugin spec..."

cat > "$NVIM_DIR/lua/plugins/diffview.lua" << 'DIFFEOF'
return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diff view (working changes)" },
      { "<leader>gD", "<cmd>DiffviewOpen main<cr>", desc = "Diff view (against main)" },
      { "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", desc = "File history (current file)" },
      { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Close diff view" },
    },
    opts = {},
  },
}
DIFFEOF
echo "  plugins/diffview.lua: OK"
