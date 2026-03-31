#!/usr/bin/env bash
# hyprland: rollback hyprland calendar window rule
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/hyprland.conf" ]]; then
  echo "hyprland.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko komarchy calendar ---' "$HYPR/hyprland.conf"; then
  echo "removing calendar rule..."
  sed -i '/# --- BEGIN ko komarchy calendar ---/,/# --- END ko komarchy calendar ---/d' "$HYPR/hyprland.conf"
  echo "hyprland.conf reverted"
else
  echo "calendar rule not found, skipping"
fi
