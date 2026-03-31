#!/usr/bin/env bash
# libre: LibreOffice Wayland scaling fix
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ -f "$HYPR/envs.conf" ]] && grep -q 'SAL_USE_VCLPLUGIN' "$HYPR/envs.conf"; then
  echo "LibreOffice env already configured, skipping"
  exit 0
fi

echo "patching envs.conf..."

cat >> "$HYPR/envs.conf" << 'EOF'

# --- BEGIN ko omarchy-setup libre ---
# LibreOffice Wayland scaling fix
env = SAL_USE_VCLPLUGIN,gtk3
# --- END ko omarchy-setup libre ---
EOF

# source envs.conf from hyprland.conf if not already
if ! grep -q 'source = ~/.config/hypr/envs.conf' "$HYPR/hyprland.conf"; then
  sed -i '/source = ~\/.local\/share\/omarchy\/default\/hypr\/envs.conf/a source = ~/.config/hypr/envs.conf' "$HYPR/hyprland.conf"
  echo "hyprland.conf updated to source envs.conf"
fi

echo "envs.conf patched"
