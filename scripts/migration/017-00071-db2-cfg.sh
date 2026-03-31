#!/usr/bin/env bash
# db2: neovim db2 custom password manager plugin spec
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing db2 plugin spec..."

cat > "$NVIM_DIR/lua/plugins/db2.lua" << 'DB2EOF'
-- db2 - a neovim password manager
-- Converted from VimScript: repo/dotfiles/stow/vim-db2/.vim/plugin/db2.vim

return {
  {
    dir = vim.fn.stdpath("config"),
    name = "db2",
    keys = {
      {
        "<leader>d2",
        function()
          require("util.db2").open()
        end,
        desc = "Open Db2",
      },
    },
    cmd = "Db2",
    config = function()
      vim.api.nvim_create_user_command("Db2", function(opts)
        require("util.db2").open(opts.args)
      end, { nargs = "?", complete = "file" })
    end,
  },
}
DB2EOF
echo "  plugins/db2.lua: OK"

echo ""
echo "restart nvim to apply changes"
