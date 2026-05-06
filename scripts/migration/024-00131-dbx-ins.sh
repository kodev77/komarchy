#!/usr/bin/env bash
# retro-emu: install dosbox-staging — actively-maintained Linux native DOSBox
# fork. Used by per-game launchers (SimCity series, others later).
# Lives in AUR (not extra), so this needs an AUR helper (yay or paru).
set -euo pipefail

if pacman -Qi dosbox-staging &>/dev/null; then
  echo "dosbox-staging already installed"
  exit 0
fi

echo "installing dosbox-staging from AUR..."
if command -v paru &>/dev/null; then
  paru -S --needed --noconfirm dosbox-staging
elif command -v yay &>/dev/null; then
  yay -S --needed --noconfirm dosbox-staging
else
  echo "no AUR helper found (paru/yay), cannot install dosbox-staging"
  exit 1
fi

# verify — yay/paru can return 0 even when AUR lookup finds nothing
if ! pacman -Qi dosbox-staging &>/dev/null; then
  echo "dosbox-staging did not install (AUR lookup may have failed)"
  exit 1
fi
echo "dosbox-staging installed"
