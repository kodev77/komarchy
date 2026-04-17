#!/usr/bin/env bash
# waybar: rollback arrow-leftmost reorder
set -euo pipefail

CONFIG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$CONFIG" ]]; then
  echo "waybar config not found, skipping"
  exit 0
fi

# idempotency: if "custom/teams" is already before "group/tray-expander", done
prev=$(grep -B1 '^    "group/tray-expander",$' "$CONFIG" | head -1 | tr -d '[:space:]')
if [[ "$prev" == *'custom/teams'* ]]; then
  echo "teams dot already sits before arrow (rollback already applied)"
  exit 0
fi

sed -i '/^    "group\/tray-expander",$/{N;s|^    "group/tray-expander",\n    "custom/teams",$|    "custom/teams",\n    "group/tray-expander",|}' "$CONFIG"

echo "  modules-right reordered back: teams-dot | arrow | bluetooth | ..."
pkill -SIGUSR2 waybar 2>/dev/null || true
