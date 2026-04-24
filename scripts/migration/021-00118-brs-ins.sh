#!/usr/bin/env bash
# updates: install browsh (text-based TUI browser; renders modern web pages
# via a headless firefox backend — firefox is pulled in as a dependency)
set -euo pipefail

if pacman -Qi browsh &>/dev/null; then
  echo "browsh already installed"
  exit 0
fi

echo "installing browsh (pulls in firefox as a dependency)..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm browsh
elif command -v yay &>/dev/null; then
  yay -S --noconfirm browsh
else
  echo "no aur helper found (paru/yay), cannot install browsh"
  exit 1
fi
echo "browsh installed"

echo ""
echo "run: browsh                        (start browser)"
echo "     browsh --startup-url=DOMAIN   (open at URL)"
echo "     browsh --help                 (options)"
echo "in-app: ctrl+l to focus url bar, ctrl+q to quit"
