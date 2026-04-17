#!/usr/bin/env bash
# updates: install zen-browser (firefox-based privacy browser)
set -euo pipefail

if pacman -Qi zen-browser-bin &>/dev/null; then
  echo "zen-browser already installed"
  exit 0
fi

echo "installing zen-browser-bin..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm zen-browser-bin
elif command -v yay &>/dev/null; then
  yay -S --noconfirm zen-browser-bin
else
  echo "no aur helper found (paru/yay), cannot install zen-browser"
  exit 1
fi
echo "zen-browser installed"

echo ""
echo "launch from walker/app-menu or run: zen-browser"
