#!/usr/bin/env bash
# updates: install hexyl (colored hex viewer for the terminal)
set -euo pipefail

if pacman -Qi hexyl &>/dev/null; then
  echo "hexyl already installed"
  exit 0
fi

echo "installing hexyl..."
sudo pacman -S --noconfirm hexyl
echo "hexyl installed"

echo ""
echo "usage: hexyl FILE          # print colored hex dump"
echo "       hexyl -n 256 FILE   # limit to first 256 bytes"
