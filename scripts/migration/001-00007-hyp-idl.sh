#!/usr/bin/env bash
# hyprland: hyprland idle: 15-min screensaver, disable lock and dpms
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/hypridle.conf" ]]; then
  echo "hypridle.conf not found, skipping"
  exit 0
fi

echo "patching hypridle.conf..."

# screensaver timeout 150 → 900
sed -i 's/timeout = 150 /timeout = 900 /' "$HYPR/hypridle.conf"
sed -i 's/# 2\.5min/# 15min/' "$HYPR/hypridle.conf"

# comment out lock listener block (timeout = 151)
sed -i '/timeout = 151/s/^/#/' "$HYPR/hypridle.conf"
sed -i '/on-timeout = loginctl lock-session/s/^/#/' "$HYPR/hypridle.conf"

# comment out dpms listener block (timeout = 330)
sed -i '/timeout = 330/s/^/#/' "$HYPR/hypridle.conf"
sed -i '/on-timeout = hyprctl dispatch dpms off/s/^/#/' "$HYPR/hypridle.conf"
sed -i '/on-resume = hyprctl dispatch dpms on/s/^/#/' "$HYPR/hypridle.conf"

echo "hypridle.conf patched"
