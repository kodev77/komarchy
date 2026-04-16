#!/usr/bin/env bash
# neovim: rollback lazyvim extra: markdown
set -euo pipefail

LAZYVIM="$HOME/.config/nvim/lazyvim.json"

if [[ ! -f "$LAZYVIM" ]] || ! grep -q "lazyvim.plugins.extras.lang.markdown" "$LAZYVIM"; then
  echo "lang.markdown extra not found, skipping"
  exit 0
fi

echo "removing lang.markdown extra..."
sed -i '/"lazyvim.plugins.extras.lang.markdown"/d' "$LAZYVIM"
# clean up trailing comma if needed
sed -i ':a;N;$!ba;s/,\n\s*]/\n    ]/g' "$LAZYVIM"
echo "lang.markdown extra removed"

# remove any mason tools installed by the markdown extra
for tool in marksman markdown-toc; do
  echo "uninstalling $tool from mason..."
  nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, '$tool'); if ok and p:is_installed() then p:uninstall(); print('uninstalled') else print('not installed, skipping') end" -c "sleep 2" -c "qa" 2>&1 || true
done
