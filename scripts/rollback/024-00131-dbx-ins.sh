#!/usr/bin/env bash
# retro-emu: rollback dosbox-staging install.
set -euo pipefail

if pacman -Qi dosbox-staging &>/dev/null; then
  echo "removing dosbox-staging..."
  sudo pacman -Rns --noconfirm dosbox-staging
  echo "dosbox-staging removed"
else
  echo "dosbox-staging not installed"
fi
