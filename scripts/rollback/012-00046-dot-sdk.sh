#!/usr/bin/env bash
# dotnet: rollback .net sdk and runtime for building and running c# applications and web apis
set -euo pipefail

echo "removing dotnet packages..."
for pkg in dotnet-sdk dotnet-runtime aspnet-runtime aspnet-targeting-pack dotnet-sdk-9.0 dotnet-runtime-9.0 aspnet-runtime-9.0 aspnet-targeting-pack-9.0; do
  if pacman -Qi "$pkg" &>/dev/null; then
    sudo pacman -Rns --noconfirm "$pkg" || true
    echo "  $pkg removed"
  fi
done

echo ""
echo "cleaning removed neovim plugins..."
nvim --headless -c "lua require('lazy').clean({wait=true})" -c "sleep 3" -c "qa" 2>&1 || true

echo "updating treesitter parsers..."
nvim --headless -c "TSUpdate" -c "sleep 5" -c "qa" 2>&1 || true

echo "  dotnet cleanup: OK"

echo ""
echo "restart nvim to apply changes"
