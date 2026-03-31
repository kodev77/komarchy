#!/usr/bin/env bash
# berkeley: rollback waybar font to JetBrainsMono
set -euo pipefail

WAYBAR_CSS="$HOME/.config/waybar/style.css"

if [[ ! -f "$WAYBAR_CSS" ]]; then
  echo "waybar style.css not found, skipping"
  exit 0
fi

echo "reverting waybar font..."
sed -i "s/font-family: 'Berkeley Mono';/font-family: 'JetBrainsMono Nerd Font';/" "$WAYBAR_CSS"
echo "waybar font reverted"

echo ""
echo "restarting waybar..."
killall waybar 2>/dev/null; waybar &>/dev/null &disown
echo "waybar restarted"
