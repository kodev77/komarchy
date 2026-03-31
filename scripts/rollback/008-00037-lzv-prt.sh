#!/usr/bin/env bash
# neovim: rollback lazyvim extra: prettier code formatting
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"

if [[ ! -f "$LAZYVIM" ]] || ! grep -q "lazyvim.plugins.extras.formatting.prettier" "$LAZYVIM"; then
  echo "formatting.prettier extra not found, skipping"
  exit 0
fi

echo "removing formatting.prettier extra..."
sed -i '/"lazyvim.plugins.extras.formatting.prettier"/d' "$LAZYVIM"
# clean up trailing comma if needed
sed -i ':a;N;$!ba;s/,\n\s*]/\n    ]/g' "$LAZYVIM"
echo "formatting.prettier extra removed"

echo "uninstalling prettier from mason..."
nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, 'prettier'); if ok and p:is_installed() then p:uninstall(); print('uninstalled') else print('not installed, skipping') end" -c "sleep 2" -c "qa" 2>&1 || true
