#!/usr/bin/env bash
# updates: rollback zen-browser install
set -euo pipefail

if ! pacman -Qi zen-browser-bin &>/dev/null; then
  echo "zen-browser not installed, skipping"
  exit 0
fi

echo "removing zen-browser-bin..."
sudo pacman -Rns --noconfirm zen-browser-bin
echo "zen-browser removed"
