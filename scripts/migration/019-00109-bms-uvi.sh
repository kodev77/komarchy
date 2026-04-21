#!/usr/bin/env bash
# bm-tool: install uv (Python package manager) if missing
set -euo pipefail

if command -v uv >/dev/null 2>&1; then
  echo "uv already installed ($(uv --version))"
  exit 0
fi

if pacman -Qi uv >/dev/null 2>&1; then
  echo "uv installed via pacman but not on PATH — investigate manually"
  exit 0
fi

echo "installing uv"
sudo pacman -S --noconfirm --needed uv
echo "uv installed"
