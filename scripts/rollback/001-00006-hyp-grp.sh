#!/usr/bin/env bash
# hyprland: rollback hyprland stacked groupbar
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/looknfeel.conf" ]]; then
  echo "looknfeel.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko komarchy groupbar ---' "$HYPR/looknfeel.conf"; then
  echo "removing groupbar..."
  sed -i '/# --- BEGIN ko komarchy groupbar ---/,/# --- END ko komarchy groupbar ---/d' "$HYPR/looknfeel.conf"
  echo "looknfeel.conf reverted"
else
  echo "groupbar not found, skipping"
fi
