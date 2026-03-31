#!/usr/bin/env bash
# db2: neovim db2 utility module (used by the db2 plugin spec)
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/util"

echo "Copying db2 util module..."
cp "$REPO_DIR/files/config/nvim/lua/util/db2.lua" "$NVIM_DIR/lua/util/"
echo "  util/db2.lua: OK"
