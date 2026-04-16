#!/usr/bin/env bash
# updates: install teams-for-linux (unofficial Electron wrapper for Microsoft Teams)
set -euo pipefail

if pacman -Qi teams-for-linux &>/dev/null; then
  echo "teams-for-linux already installed"
  exit 0
fi

echo "installing teams-for-linux..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm teams-for-linux
elif command -v yay &>/dev/null; then
  yay -S --noconfirm teams-for-linux
else
  echo "no aur helper found (paru/yay), cannot install teams-for-linux"
  exit 1
fi
echo "teams-for-linux installed"

echo ""
echo "launch from walker/app-menu or run: teams-for-linux"
