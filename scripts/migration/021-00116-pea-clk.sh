#!/usr/bin/env bash
# updates: install peaclock (binary/analog/digital terminal clock with timer
# and stopwatch modes; supports subsecond precision)
set -euo pipefail

if pacman -Qi peaclock &>/dev/null; then
  echo "peaclock already installed"
  exit 0
fi

echo "installing peaclock..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm peaclock
elif command -v yay &>/dev/null; then
  yay -S --noconfirm peaclock
else
  echo "no aur helper found (paru/yay), cannot install peaclock"
  exit 1
fi
echo "peaclock installed"

echo ""
echo "run: peaclock              (default binary clock)"
echo "     peaclock --help       (full option list)"
