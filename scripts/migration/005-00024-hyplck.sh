#!/usr/bin/env bash
# berkeley: hyprland lock screen font swap to Berkeley Mono
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/hyprlock.conf" ]]; then
  echo "hyprlock.conf not found, skipping"
  exit 0
fi

if ! ls "$HOME/.local/share/fonts"/BerkeleyMono*.ttf &>/dev/null; then
  echo "berkeley mono not installed, skipping"
  exit 2
fi

echo "patching hyprlock font..."
sed -i 's/font_family = JetBrainsMono Nerd Font/font_family = Berkeley Mono/' "$HYPR/hyprlock.conf"
echo "hyprlock font patched"
