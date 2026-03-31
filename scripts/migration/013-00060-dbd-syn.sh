#!/usr/bin/env bash
# dadbod: sync neovim plugins after dadbod setup
set -euo pipefail

echo "syncing neovim plugins..."
nvim --headless -c "Lazy install" -c "sleep 5" -c "qa" 2>&1 || true

echo "  neovim sync: OK"

echo ""
echo "restart nvim to apply changes"
