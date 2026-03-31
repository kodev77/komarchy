#!/usr/bin/env bash
# hyprland: terminal calendar app for waybar clock right-click
set -euo pipefail

if pacman -Qi lvsk-calendar &>/dev/null; then
  echo "lvsk-calendar already installed"
else
  echo "installing lvsk-calendar..."
  if command -v paru &>/dev/null; then
    paru -S --noconfirm lvsk-calendar
  elif command -v yay &>/dev/null; then
    yay -S --noconfirm lvsk-calendar
  else
    echo "no aur helper found (paru/yay), cannot install lvsk-calendar"
    exit 1
  fi
  echo "lvsk-calendar installed"
fi
