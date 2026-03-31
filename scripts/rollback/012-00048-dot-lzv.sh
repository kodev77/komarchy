#!/usr/bin/env bash
# dotnet: rollback lazyvim extra: dotnet language support
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"

if [[ ! -f "$LAZYVIM" ]] || ! grep -q "lazyvim.plugins.extras.lang.dotnet" "$LAZYVIM"; then
  echo "lang.dotnet extra not found, skipping"
  exit 0
fi

echo "removing lang.dotnet extra..."
sed -i '/"lazyvim.plugins.extras.lang.dotnet"/d' "$LAZYVIM"
# clean up trailing comma if needed
sed -i ':a;N;$!ba;s/,\n\s*]/\n    ]/g' "$LAZYVIM"
echo "lang.dotnet extra removed"

# remove mason tools installed by the dotnet extra
for tool in omnisharp netcoredbg csharpier fantomas; do
  echo "uninstalling $tool from mason..."
  nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, '$tool'); if ok and p:is_installed() then p:uninstall(); print('uninstalled') else print('not installed, skipping') end" -c "sleep 2" -c "qa" 2>&1 || true
done
