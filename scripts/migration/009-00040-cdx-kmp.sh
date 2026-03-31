#!/usr/bin/env bash
# neovim-cdexit: neovim keymaps: quit-and-cd-shell (leader-qd) and quit-to-home (leader-qh)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"

echo "Patching nvim keymaps..."

KEYMAPS="$NVIM_DIR/lua/config/keymaps.lua"
if [[ -f "$KEYMAPS" ]] && ! grep -q 'leader>qd' "$KEYMAPS"; then
  cat >> "$KEYMAPS" << 'KEYMAPSEOF'

-- Quit and tell the shell to cd to nvim's cwd (or Neo-tree directory under cursor)
vim.keymap.set("n", "<leader>qd", function()
  local dir = vim.fn.getcwd()

  if vim.bo.filetype == "neo-tree" then
    local ok, manager = pcall(require, "neo-tree.sources.manager")
    if ok then
      local state = manager.get_state("filesystem")
      local node = state.tree:get_node()
      if node then
        local path = node:get_id()
        if vim.fn.isdirectory(path) == 1 then
          dir = path
        else
          dir = vim.fn.fnamemodify(path, ":h")
        end
      end
    end
  end

  local f = io.open(vim.fn.expand("~/.nvim_cwd"), "w")
  if f then
    f:write(dir)
    f:close()
  end
  vim.cmd("qa")
end, { desc = "Quit and cd shell to cwd" })

-- Quit and tell the shell to cd to home directory
vim.keymap.set("n", "<leader>qh", function()
  local f = io.open(vim.fn.expand("~/.nvim_cwd"), "w")
  if f then
    f:write(vim.fn.expand("~"))
    f:close()
  end
  vim.cmd("qa")
end, { desc = "Quit and cd shell to ~" })
KEYMAPSEOF
  echo "  keymaps.lua: patched"
fi

echo ""
echo "open a new terminal and restart nvim to apply changes"
