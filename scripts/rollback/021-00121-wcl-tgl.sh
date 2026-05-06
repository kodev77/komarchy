#!/usr/bin/env bash
# updates: rollback waycal toggle - restore plain waycal binding
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "waybar config not found, skipping"
  exit 0
fi

if grep -q '"on-click-right": "waycal"$' "$WAYBAR_CFG"; then
  echo "plain waycal binding already in place, skipping"
  exit 0
fi

if ! grep -q '"on-click-right": "pkill -x waycal || waycal"' "$WAYBAR_CFG"; then
  echo "waycal toggle binding not found, skipping"
  exit 0
fi

awk '
  /"on-click-right": "pkill -x waycal \|\| waycal"$/ {
    sub(/"on-click-right": "pkill -x waycal \|\| waycal"/, "\"on-click-right\": \"waycal\"")
  }
  { print }
' "$WAYBAR_CFG" > "$WAYBAR_CFG.tmp" && mv "$WAYBAR_CFG.tmp" "$WAYBAR_CFG"
echo "  waybar: restored plain waycal binding"

pkill -SIGUSR2 waybar 2>/dev/null || true
