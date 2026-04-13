#!/usr/bin/env bash
# updates: rollback yazi terminal file manager
set -euo pipefail

if ! pacman -Qi yazi &>/dev/null; then
  echo "yazi not installed, skipping"
  exit 0
fi

echo "removing yazi..."
sudo pacman -Rns --noconfirm yazi
echo "yazi removed"
