#!/usr/bin/env bash
# typescript: rollback lazyvim extra: typescript language support
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"

if [[ ! -f "$LAZYVIM" ]] || ! grep -q "lazyvim.plugins.extras.lang.typescript" "$LAZYVIM"; then
  echo "lang.typescript extra not found, skipping"
  exit 0
fi

echo "removing lang.typescript extra..."
sed -i '/"lazyvim.plugins.extras.lang.typescript"/d' "$LAZYVIM"
# clean up trailing comma if needed
sed -i ':a;N;$!ba;s/,\n\s*]/\n    ]/g' "$LAZYVIM"
echo "lang.typescript extra removed"

# remove mason tools installed by the typescript extra
for tool in typescript-language-server vtsls js-debug-adapter; do
  echo "uninstalling $tool from mason..."
  nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, '$tool'); if ok and p:is_installed() then p:uninstall(); print('uninstalled') else print('not installed, skipping') end" -c "sleep 2" -c "qa" 2>&1 || true
done

echo ""
echo "cleaning removed neovim plugins..."
nvim --headless -c "lua require('lazy').clean({wait=true})" -c "sleep 3" -c "qa" 2>&1 || true

echo "updating treesitter parsers..."
nvim --headless -c "TSUpdate" -c "sleep 5" -c "qa" 2>&1 || true

echo "  typescript cleanup: OK"

echo ""
echo "restart nvim to apply changes"
