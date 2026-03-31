#!/usr/bin/env bash
# hyprland: hyprland window rule for calendar app sizing
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/hyprland.conf" ]]; then
  echo "hyprland.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko komarchy calendar ---' "$HYPR/hyprland.conf"; then
  echo "calendar rule already configured, skipping"
  exit 0
fi

echo "patching hyprland.conf..."

cat >> "$HYPR/hyprland.conf" << 'EOF'

# --- BEGIN ko komarchy calendar ---
windowrule = size 1200 700, match:title ^lvsk-calendar$
# --- END ko komarchy calendar ---
EOF

echo "hyprland.conf patched"
