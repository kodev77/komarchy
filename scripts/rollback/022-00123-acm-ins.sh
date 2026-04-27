#!/usr/bin/env bash
# retro: rollback ACME assembler install
set -euo pipefail

if pacman -Qi acme &>/dev/null; then
  echo "removing acme..."
  sudo pacman -Rns --noconfirm acme
  echo "acme removed"
else
  echo "acme not installed, skipping"
fi
