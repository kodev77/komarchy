#!/usr/bin/env bash
# updates: rollback peaclock install
set -euo pipefail

if ! pacman -Qi peaclock &>/dev/null; then
  echo "peaclock not installed, skipping"
  exit 0
fi

echo "removing peaclock..."
sudo pacman -Rns --noconfirm peaclock
echo "peaclock removed"
