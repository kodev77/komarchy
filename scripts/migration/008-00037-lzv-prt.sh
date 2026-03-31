#!/usr/bin/env bash
# neovim: lazyvim extra: prettier code formatting
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"
if [[ -f "$LAZYVIM" ]] && ! grep -q "lazyvim.plugins.extras.formatting.prettier" "$LAZYVIM"; then
  sed -i 's|"lazyvim.plugins.extras.editor.neo-tree"|"lazyvim.plugins.extras.editor.neo-tree",\n    "lazyvim.plugins.extras.formatting.prettier"|' "$LAZYVIM"
fi
echo "  lazyvim extra: formatting.prettier"
