#!/usr/bin/env bash
# updates: rollback tty-clock install
set -euo pipefail

if ! pacman -Qi tty-clock &>/dev/null; then
  echo "tty-clock not installed, skipping"
  exit 0
fi

echo "removing tty-clock..."
sudo pacman -Rns --noconfirm tty-clock
echo "tty-clock removed"
