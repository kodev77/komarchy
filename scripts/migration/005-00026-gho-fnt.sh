#!/usr/bin/env bash
# berkeley: ghostty: swap font to Berkeley Mono
set -euo pipefail

GHOSTTY_CFG="$HOME/.config/ghostty/config"

if [[ ! -f "$GHOSTTY_CFG" ]]; then
  echo "ghostty config not found, skipping"
  exit 0
fi

if ! ls "$HOME/.local/share/fonts"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono not installed, skipping"
  exit 2
fi

echo "patching ghostty font..."
sed -i 's/font-family = "JetBrainsMono Nerd Font"/font-family = "Berkeley Mono"/' "$GHOSTTY_CFG"
sed -i 's/font-family = JetBrainsMono Nerd Font/font-family = Berkeley Mono/' "$GHOSTTY_CFG"
echo "ghostty font patched"

echo ""
echo "close all open terminals and open a new terminal to see changes"
