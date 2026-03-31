#!/usr/bin/env bash
# neovim: neovim gitsigns keybinding overrides for hunk navigation and staging
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing gitsigns plugin spec..."

cat > "$NVIM_DIR/lua/plugins/gitsigns.lua" << 'GSEOF'
return {
  "lewis6991/gitsigns.nvim",
  opts = function(_, opts)
    opts.on_attach = function(buffer)
      local gs = require("gitsigns")

      local function map(mode, l, r, desc)
        vim.keymap.set(mode, l, r, { buffer = buffer, desc = desc })
      end

      map("n", "]h", function() gs.nav_hunk("next") end, "Next Hunk")
      map("n", "[h", function() gs.nav_hunk("prev") end, "Prev Hunk")
      map("n", "<leader>hp", gs.preview_hunk, "Preview Hunk")
      map("n", "<leader>hs", gs.stage_hunk, "Stage Hunk")
      map("n", "<leader>hr", gs.reset_hunk, "Reset Hunk")
      map("n", "<leader>hS", gs.stage_buffer, "Stage Buffer")
      map("n", "<leader>hu", gs.undo_stage_hunk, "Undo Stage Hunk")
      map("n", "<leader>hi", gs.preview_hunk_inline, "Preview Hunk Inline")
      map("n", "<leader>hd", gs.diffthis, "Diff This")
      map("n", "<leader>hD", "<cmd>DiffviewOpen<cr>", "Diffview Open")
      map("n", "<leader>hb", function() gs.blame_line({ full = true }) end, "Blame Line")
    end
  end,
}
GSEOF
echo "  plugins/gitsigns.lua: OK"
