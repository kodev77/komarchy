#!/usr/bin/env bash
# hyprland: waycal calendar popup for waybar clock right-click
set -euo pipefail

if pacman -Qi waycal &>/dev/null; then
  echo "waycal already installed"
else
  echo "installing waycal..."
  if command -v paru &>/dev/null; then
    paru -S --noconfirm waycal
  elif command -v yay &>/dev/null; then
    yay -S --noconfirm waycal
  else
    echo "no aur helper found (paru/yay), cannot install waycal"
    exit 1
  fi
  echo "waycal installed"
fi
