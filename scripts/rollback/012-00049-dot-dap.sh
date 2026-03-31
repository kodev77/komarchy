#!/usr/bin/env bash
# dotnet: rollback neovim DAP launch config for C# test project
set -euo pipefail

PLUGIN="$HOME/.config/nvim/lua/plugins/dap-dotnet.lua"

if [[ ! -f "$PLUGIN" ]]; then
  echo "dap-dotnet plugin not found, skipping"
  exit 0
fi

echo "removing dap-dotnet plugin spec..."
rm "$PLUGIN"
echo "dap-dotnet plugin removed"
