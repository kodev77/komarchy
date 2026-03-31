#!/usr/bin/env bash
# waybar: waybar: 12h clock format and calendar right-click
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

# clock right-click: timezone picker → calendar app
sed -i 's|"on-click-right": "omarchy-launch-floating-terminal-with-presentation omarchy-tz-select"|"on-click-right": "bash -c '"'"'hyprctl keyword windowrule \\"float on, match:title ^lvsk-calendar$\\" \&\& hyprctl keyword windowrule \\"size 1200 700, match:title ^lvsk-calendar$\\" \&\& hyprctl keyword windowrule \\"center on, match:title ^lvsk-calendar$\\" \&\& ghostty --title=lvsk-calendar --quit-after-last-window-closed -e /usr/bin/lvsk-calendar'"'"'"|' "$WAYBAR_CFG"

echo "waybar clock patched"
