#!/usr/bin/env bash
# hyprland: rollback hyprland stacked groupbar
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/looknfeel.conf" ]]; then
  echo "looknfeel.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko omarchy-setup groupbar ---' "$HYPR/looknfeel.conf"; then
  echo "removing groupbar..."
  sed -i '/# --- BEGIN ko omarchy-setup groupbar ---/,/# --- END ko omarchy-setup groupbar ---/d' "$HYPR/looknfeel.conf"
  echo "looknfeel.conf reverted"
else
  echo "groupbar not found, skipping"
fi
