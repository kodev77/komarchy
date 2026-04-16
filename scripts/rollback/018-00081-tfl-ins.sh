#!/usr/bin/env bash
# updates: rollback teams-for-linux install
set -euo pipefail

if ! pacman -Qi teams-for-linux &>/dev/null; then
  echo "teams-for-linux not installed, skipping"
  exit 0
fi

echo "removing teams-for-linux..."
sudo pacman -Rns --noconfirm teams-for-linux
echo "teams-for-linux removed"
