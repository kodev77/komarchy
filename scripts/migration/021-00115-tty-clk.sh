#!/usr/bin/env bash
# updates: install tty-clock (ncurses digital clock for the terminal)
set -euo pipefail

if pacman -Qi tty-clock &>/dev/null; then
  echo "tty-clock already installed"
  exit 0
fi

echo "installing tty-clock..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm tty-clock
elif command -v yay &>/dev/null; then
  yay -S --noconfirm tty-clock
else
  echo "no aur helper found (paru/yay), cannot install tty-clock"
  exit 1
fi
echo "tty-clock installed"

echo ""
echo "run: tty-clock -c -C 6 -s  (centered, cyan, seconds)"
