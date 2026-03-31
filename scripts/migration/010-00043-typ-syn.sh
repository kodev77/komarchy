#!/usr/bin/env bash
# typescript: sync neovim plugins, treesitter parsers, and mason tools
set -euo pipefail

echo "syncing neovim plugins..."
nvim --headless -c "Lazy install" -c "sleep 5" -c "qa" 2>&1 || true

echo "updating treesitter parsers..."
nvim --headless -c "TSUpdate" -c "sleep 5" -c "qa" 2>&1 || true

echo "updating mason tools..."
nvim --headless -c "lua require('mason-registry').update(function() print('mason registry updated') end)" -c "sleep 5" -c "qa" 2>&1 || true

echo "installing mason tools..."
for tool in vtsls angular-language-server; do
  nvim --headless -c "lua local r = require('mason-registry'); local ok, p = pcall(r.get_package, '$tool'); if ok and not p:is_installed() then p:install(); print('installing $tool') else print('$tool: already installed or not found') end" -c "sleep 5" -c "qa" 2>&1 || true
done

echo "  neovim sync: OK"

echo ""
echo "restart nvim to apply changes"
