#!/usr/bin/env bash
# dadbod: neovim dadbod-format utility module (used by dadbod plugins)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/util"

echo "Copying dadbod-format util module..."
cp "$REPO_DIR/files/config/nvim/lua/util/dadbod-format.lua" "$NVIM_DIR/lua/util/"
echo "  util/dadbod-format.lua: OK"
