#!/usr/bin/env bash
# dotnet: lazyvim extra: dotnet language support
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"
if [[ -f "$LAZYVIM" ]] && ! grep -q "lazyvim.plugins.extras.lang.dotnet" "$LAZYVIM"; then
  sed -i 's|"lazyvim.plugins.extras.editor.neo-tree"|"lazyvim.plugins.extras.editor.neo-tree",\n    "lazyvim.plugins.extras.lang.dotnet"|' "$LAZYVIM"
fi
echo "  lazyvim extra: lang.dotnet"
