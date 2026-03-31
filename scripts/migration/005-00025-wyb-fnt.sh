#!/usr/bin/env bash
# berkeley: waybar: swap font to Berkeley Mono
set -euo pipefail

WAYBAR_CSS="$HOME/.config/waybar/style.css"

if [[ ! -f "$WAYBAR_CSS" ]]; then
  echo "waybar style.css not found, skipping"
  exit 0
fi

if ! ls "$HOME/.local/share/fonts"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono not installed, skipping"
  exit 2
fi

echo "patching waybar font..."
sed -i "s/font-family: 'JetBrainsMono Nerd Font';/font-family: 'Berkeley Mono';/" "$WAYBAR_CSS"
echo "waybar font patched"

echo ""
echo "restarting waybar..."
killall waybar 2>/dev/null; waybar &>/dev/null &disown
echo "waybar restarted"
