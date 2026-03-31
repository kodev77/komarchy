#!/usr/bin/env bash
# hyprland: rollback hyprland idle settings
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/hypridle.conf" ]]; then
  echo "hypridle.conf not found, skipping"
  exit 0
fi

echo "reverting hypridle.conf..."

# screensaver timeout 900 → 150
sed -i 's/timeout = 900 /timeout = 150 /' "$HYPR/hypridle.conf"
sed -i 's/# 15min/# 2.5min/' "$HYPR/hypridle.conf"

# uncomment lock listener
sed -i '/timeout = 151/s/^#//' "$HYPR/hypridle.conf"
sed -i '/on-timeout = loginctl lock-session/s/^#//' "$HYPR/hypridle.conf"

# uncomment dpms listener
sed -i '/timeout = 330/s/^#//' "$HYPR/hypridle.conf"
sed -i '/on-timeout = hyprctl dispatch dpms off/s/^#//' "$HYPR/hypridle.conf"
sed -i '/on-resume = hyprctl dispatch dpms on/s/^#//' "$HYPR/hypridle.conf"

echo "hypridle.conf reverted"
