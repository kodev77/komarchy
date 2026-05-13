#!/usr/bin/env bash
# bm-chromium: rollback wtype install
set -euo pipefail

if ! pacman -Qi wtype &>/dev/null; then
  echo "wtype not installed, nothing to roll back"
  exit 0
fi

echo "removing wtype..."
sudo pacman -Rns --noconfirm wtype
echo "wtype removed"
