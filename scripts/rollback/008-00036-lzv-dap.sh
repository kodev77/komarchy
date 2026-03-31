#!/usr/bin/env bash
# neovim: rollback lazyvim extra: debug adapter protocol (DAP) core
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"

if [[ ! -f "$LAZYVIM" ]] || ! grep -q "lazyvim.plugins.extras.dap.core" "$LAZYVIM"; then
  echo "dap.core extra not found, skipping"
  exit 0
fi

echo "removing dap.core extra..."
sed -i '/"lazyvim.plugins.extras.dap.core"/d' "$LAZYVIM"
# clean up trailing comma if needed
sed -i ':a;N;$!ba;s/,\n\s*]/\n    ]/g' "$LAZYVIM"
echo "dap.core extra removed"

# remove any mason tools installed by the dap extra
for tool in debugpy js-debug-adapter; do
  echo "uninstalling $tool from mason..."
  nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, '$tool'); if ok and p:is_installed() then p:uninstall(); print('uninstalled') else print('not installed, skipping') end" -c "sleep 2" -c "qa" 2>&1 || true
done
