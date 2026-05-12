#!/usr/bin/env bash
# hyprland: rollback waycal calendar popup
set -euo pipefail

if pacman -Qi waycal &>/dev/null; then
  echo "removing waycal..."
  sudo pacman -Rns --noconfirm waycal
  echo "waycal removed"
else
  echo "waycal not installed, skipping"
fi
