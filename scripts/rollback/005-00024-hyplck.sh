#!/usr/bin/env bash
# berkeley: rollback hyprlock font to JetBrainsMono
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/hyprlock.conf" ]]; then
  echo "hyprlock.conf not found, skipping"
  exit 0
fi

echo "reverting hyprlock font..."
sed -i 's/font_family = Berkeley Mono/font_family = JetBrainsMono Nerd Font/' "$HYPR/hyprlock.conf"
echo "hyprlock font reverted"
