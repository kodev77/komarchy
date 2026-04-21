#!/usr/bin/env bash
# bm-tool: rollback uv install
set -euo pipefail

if ! pacman -Qi uv >/dev/null 2>&1; then
  echo "uv not installed via pacman, skipping"
  exit 0
fi

echo "removing uv"
sudo pacman -Rns --noconfirm uv
echo "uv removed"
