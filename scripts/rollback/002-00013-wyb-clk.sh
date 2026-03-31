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

# clock right-click: calendar app → timezone picker
sed -i 's|"on-click-right": "bash -c '"'"'hyprctl keyword windowrule \\"float on, match:title ^lvsk-calendar$\\" \&\& hyprctl keyword windowrule \\"size 1200 700, match:title ^lvsk-calendar$\\" \&\& hyprctl keyword windowrule \\"center on, match:title ^lvsk-calendar$\\" \&\& ghostty --title=lvsk-calendar --quit-after-last-window-closed -e /usr/bin/lvsk-calendar'"'"'"|"on-click-right": "omarchy-launch-floating-terminal-with-presentation omarchy-tz-select"|' "$WAYBAR_CFG"

echo "waybar clock reverted"
