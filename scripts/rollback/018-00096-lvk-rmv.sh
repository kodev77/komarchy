#!/usr/bin/env bash
# updates: rollback lvsk-calendar removal (reinstall + restore hyprland rule)
set -euo pipefail

HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

# --- 1. reinstall lvsk-calendar from AUR ---
if ! pacman -Qi lvsk-calendar &>/dev/null; then
  echo "  reinstalling lvsk-calendar from AUR..."
  if command -v paru &>/dev/null; then
    paru -S --noconfirm lvsk-calendar
  elif command -v yay &>/dev/null; then
    yay -S --noconfirm lvsk-calendar
  else
    echo "  no aur helper found (paru/yay), cannot reinstall"
    exit 1
  fi
fi

# --- 2. restore hyprland windowrule block ---
if [[ -f "$HYPR_CONF" ]] && ! grep -q '# --- BEGIN ko komarchy calendar ---' "$HYPR_CONF"; then
  cat >> "$HYPR_CONF" << 'EOF'

# --- BEGIN ko komarchy calendar ---
windowrule = size 1200 700, match:title ^lvsk-calendar$
# --- END ko komarchy calendar ---
EOF
  echo "  restored lvsk-calendar block in hyprland.conf"
fi

echo ""
echo "lvsk-calendar reinstalled. user config ~/.config/lvsk-calendar/ will be"
echo "regenerated with defaults on next launch."
echo "(to use it again as the clock calendar, also rollback 018-00095)"
