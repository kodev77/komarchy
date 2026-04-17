#!/usr/bin/env bash
# waybar: move tray-expander arrow to leftmost position (before custom/teams dot)
set -euo pipefail

CONFIG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$CONFIG" ]]; then
  echo "waybar config not found, skipping"
  exit 2
fi

# idempotency: if the line before "custom/teams" is already "group/tray-expander", done
prev=$(grep -B1 '^    "custom/teams",$' "$CONFIG" | head -1 | tr -d '[:space:]')
if [[ "$prev" == *'group/tray-expander'* ]]; then
  echo "arrow already sits before teams dot"
  exit 0
fi

# swap the two adjacent lines
sed -i '/^    "custom\/teams",$/{N;s|^    "custom/teams",\n    "group/tray-expander",$|    "group/tray-expander",\n    "custom/teams",|}' "$CONFIG"

# verify swap succeeded
prev=$(grep -B1 '^    "custom/teams",$' "$CONFIG" | head -1 | tr -d '[:space:]')
if [[ "$prev" != *'group/tray-expander'* ]]; then
  echo "swap failed — check $CONFIG manually"
  exit 1
fi

echo "  modules-right reordered: arrow | teams-dot | bluetooth | ..."
pkill -SIGUSR2 waybar 2>/dev/null || true
echo ""
echo "waybar reloaded."
