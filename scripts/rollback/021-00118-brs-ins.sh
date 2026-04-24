#!/usr/bin/env bash
# updates: rollback browsh install (also removes firefox if it was pulled in
# solely as a browsh dependency; `pacman -Rns` handles that automatically)
set -euo pipefail

if ! pacman -Qi browsh &>/dev/null; then
  echo "browsh not installed, skipping"
  exit 0
fi

echo "removing browsh..."
sudo pacman -Rns --noconfirm browsh
echo "browsh removed"
