#!/usr/bin/env bash
# updates: make waybar clock right-click toggle waycal (close on second click)
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "waybar config not found, skipping"
  exit 2
fi

if grep -q '"on-click-right": "pkill -x waycal || waycal"' "$WAYBAR_CFG"; then
  echo "waycal toggle already configured"
  exit 0
fi

if ! grep -q '"on-click-right": "waycal"' "$WAYBAR_CFG"; then
  echo "plain waycal binding not found (already changed?), skipping"
  exit 2
fi

awk '
  /"on-click-right": "waycal"$/ {
    sub(/"on-click-right": "waycal"/, "\"on-click-right\": \"pkill -x waycal || waycal\"")
  }
  { print }
' "$WAYBAR_CFG" > "$WAYBAR_CFG.tmp" && mv "$WAYBAR_CFG.tmp" "$WAYBAR_CFG"
echo "  waybar: clock right-click now toggles waycal"

pkill -SIGUSR2 waybar 2>/dev/null || true
