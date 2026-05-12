#!/usr/bin/env bash
# waybar: rollback waybar clock format
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "waybar config not found, skipping"
  exit 0
fi

echo "reverting waybar clock..."

# clock format: 12h → 24h
sed -i 's/"format": "{:L%b %d %I:%M %p}"/"format": "{:L%A %H:%M}"/' "$WAYBAR_CFG"
sed -i 's/"format-alt": "{:L%A %b %Y %d %I:%M %p}"/"format-alt": "{:L%d %B W%V %Y}"/' "$WAYBAR_CFG"

# clock right-click: waycal → timezone picker
sed -i 's|"on-click-right": "waycal"|"on-click-right": "omarchy-launch-floating-terminal-with-presentation omarchy-tz-select"|' "$WAYBAR_CFG"

echo "waybar clock reverted"
