#!/usr/bin/env bash
# updates: install yazi terminal file manager
set -euo pipefail

if pacman -Qi yazi &>/dev/null; then
  echo "yazi already installed"
  exit 0
fi

echo "installing yazi..."
sudo pacman -S --noconfirm yazi
echo "yazi installed"
