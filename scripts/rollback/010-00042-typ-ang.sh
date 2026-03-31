#!/usr/bin/env bash
# typescript: rollback lazyvim extra: angular language support
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"

if [[ ! -f "$LAZYVIM" ]] || ! grep -q "lazyvim.plugins.extras.lang.angular" "$LAZYVIM"; then
  echo "lang.angular extra not found, skipping"
  exit 0
fi

echo "removing lang.angular extra..."
sed -i '/"lazyvim.plugins.extras.lang.angular"/d' "$LAZYVIM"
# clean up trailing comma if needed
sed -i ':a;N;$!ba;s/,\n\s*]/\n    ]/g' "$LAZYVIM"
echo "lang.angular extra removed"

# remove mason tools installed by the angular extra
for tool in angular-language-server; do
  echo "uninstalling $tool from mason..."
  nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, '$tool'); if ok and p:is_installed() then p:uninstall(); print('uninstalled') else print('not installed, skipping') end" -c "sleep 2" -c "qa" 2>&1 || true
done
