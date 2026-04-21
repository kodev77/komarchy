#!/usr/bin/env bash
# updates: rollback hexyl install
set -euo pipefail

if ! pacman -Qi hexyl &>/dev/null; then
  echo "hexyl not installed, skipping"
  exit 0
fi

echo "removing hexyl..."
sudo pacman -Rns --noconfirm hexyl
echo "hexyl removed"
