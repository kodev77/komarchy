#!/usr/bin/env bash
# retro: rollback AppleCommander install
set -euo pipefail

if pacman -Qi applecommander &>/dev/null; then
  echo "removing applecommander..."
  sudo pacman -Rns --noconfirm applecommander
  echo "applecommander removed"
else
  echo "applecommander not installed, skipping"
fi
