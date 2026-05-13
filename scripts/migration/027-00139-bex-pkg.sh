#!/usr/bin/env bash
# bm-chromium: install wtype (wayland keystroke injection for bm-ext-focus)
set -euo pipefail

if pacman -Qi wtype &>/dev/null; then
  echo "wtype already installed"
  exit 0
fi

echo "installing wtype..."
sudo pacman -S --noconfirm wtype
echo "wtype installed"
