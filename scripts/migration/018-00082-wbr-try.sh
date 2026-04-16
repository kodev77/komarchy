#!/usr/bin/env bash
# waybar: always show tray icons (remove the tray-expander drawer from modules-right)
set -euo pipefail

CONFIG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$CONFIG" ]]; then
  echo "waybar config.jsonc not found, skipping"
  exit 0
fi

if ! grep -qE '^    "group/tray-expander",$' "$CONFIG"; then
  echo "  waybar modules-right: already uses plain tray (or group entry not found)"
  exit 0
fi

sed -i 's|^    "group/tray-expander",$|    "tray",|' "$CONFIG"
echo "  waybar config.jsonc: modules-right now uses plain \"tray\" (always visible)"

echo ""
echo "reload waybar to apply: pkill -SIGUSR2 waybar"
