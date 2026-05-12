#!/usr/bin/env bash
# waybar: 12h clock format and waycal right-click
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "waybar config not found, skipping"
  exit 0
fi

echo "patching waybar clock..."

# clock format: 24h → 12h AM/PM
sed -i 's/"format": "{:L%A %H:%M}"/"format": "{:L%b %d %I:%M %p}"/' "$WAYBAR_CFG"
sed -i 's/"format-alt": "{:L%d %B W%V %Y}"/"format-alt": "{:L%A %b %Y %d %I:%M %p}"/' "$WAYBAR_CFG"

# clock right-click: timezone picker → waycal popup
sed -i 's|"on-click-right": "omarchy-launch-floating-terminal-with-presentation omarchy-tz-select"|"on-click-right": "waycal"|' "$WAYBAR_CFG"

echo "waybar clock patched"
