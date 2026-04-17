#!/usr/bin/env bash
# updates: replace lvsk-calendar with waycal as the waybar clock right-click
set -euo pipefail

WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

# --- 1. install waycal from AUR ---
if pacman -Qi waycal &>/dev/null; then
  echo "  waycal already installed"
else
  echo "  installing waycal from AUR..."
  if command -v paru &>/dev/null; then
    paru -S --noconfirm waycal
  elif command -v yay &>/dev/null; then
    yay -S --noconfirm waycal
  else
    echo "  no aur helper found (paru/yay), cannot install waycal"
    exit 1
  fi
fi

# --- 2. swap waybar clock on-click-right to waycal ---
if [[ ! -f "$WAYBAR_CFG" ]]; then
  echo "  waybar config not found, skipping waybar change"
  exit 0
fi

if grep -q '"on-click-right": "waycal"' "$WAYBAR_CFG"; then
  echo "  waybar clock already points at waycal"
else
  awk '
    /"on-click-right":.*lvsk-calendar/ {
      print "    \"on-click-right\": \"waycal\""
      next
    }
    { print }
  ' "$WAYBAR_CFG" > "$WAYBAR_CFG.tmp" && mv "$WAYBAR_CFG.tmp" "$WAYBAR_CFG"
  echo "  waybar: clock right-click now launches waycal"
fi

pkill -SIGUSR2 waybar 2>/dev/null || true

echo ""
echo "waycal installed. right-click the waybar clock to toggle (click again to close)."
echo "lvsk-calendar left installed — rollback this migration to switch back."
