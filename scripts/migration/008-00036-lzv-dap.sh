#!/usr/bin/env bash
# neovim: lazyvim extra: debug adapter protocol (DAP) core
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"
if [[ -f "$LAZYVIM" ]] && ! grep -q "lazyvim.plugins.extras.dap.core" "$LAZYVIM"; then
  sed -i 's|"lazyvim.plugins.extras.editor.neo-tree"|"lazyvim.plugins.extras.editor.neo-tree",\n    "lazyvim.plugins.extras.dap.core"|' "$LAZYVIM"
fi
echo "  lazyvim extra: dap.core"
