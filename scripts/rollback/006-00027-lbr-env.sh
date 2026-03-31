#!/usr/bin/env bash
# libre: rollback LibreOffice Wayland scaling fix
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/envs.conf" ]] || ! grep -q '# --- BEGIN ko komarchy libre ---' "$HYPR/envs.conf"; then
  echo "LibreOffice env not configured, skipping"
  exit 0
fi

echo "reverting LibreOffice env..."
sed -i '/# --- BEGIN ko komarchy libre ---/,/# --- END ko komarchy libre ---/d' "$HYPR/envs.conf"

# remove source line from hyprland.conf
if grep -q 'source = ~/.config/hypr/envs.conf' "$HYPR/hyprland.conf"; then
  sed -i '\|source = ~/.config/hypr/envs.conf|d' "$HYPR/hyprland.conf"
fi

# remove envs.conf if empty (only whitespace left)
if [[ -f "$HYPR/envs.conf" ]] && ! grep -q '[^[:space:]]' "$HYPR/envs.conf"; then
  rm "$HYPR/envs.conf"
fi

echo "envs.conf reverted"
