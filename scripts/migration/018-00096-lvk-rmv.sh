#!/usr/bin/env bash
# updates: remove lvsk-calendar (replaced by waycal in 018-00095)
set -euo pipefail

HYPR_CONF="$HOME/.config/hypr/hyprland.conf"
LVSK_CFG="$HOME/.config/lvsk-calendar"
WAYBAR_CFG="$HOME/.config/waybar/config.jsonc"

# --- guard: waycal must be in place, waybar must no longer reference lvsk ---
if ! pacman -Qi waycal &>/dev/null; then
  echo "  waycal not installed (run 018-00095 first), skipping"
  exit 2
fi

if [[ -f "$WAYBAR_CFG" ]] && grep -q 'lvsk-calendar' "$WAYBAR_CFG"; then
  echo "  waybar still references lvsk-calendar (run 018-00095 first), skipping"
  exit 2
fi

# --- 1. remove hyprland windowrule block (sentinel-bounded) ---
if [[ -f "$HYPR_CONF" ]] && grep -q '# --- BEGIN ko komarchy calendar ---' "$HYPR_CONF"; then
  sed -i '/^# --- BEGIN ko komarchy calendar ---$/,/^# --- END ko komarchy calendar ---$/d' "$HYPR_CONF"
  echo "  removed lvsk-calendar block from hyprland.conf"
fi

# --- 2. remove lvsk-calendar user config directory ---
if [[ -d "$LVSK_CFG" ]]; then
  rm -rf "$LVSK_CFG"
  echo "  removed $LVSK_CFG"
fi

# --- 3. uninstall AUR package ---
if pacman -Qi lvsk-calendar &>/dev/null; then
  echo "  removing lvsk-calendar package..."
  sudo pacman -Rns --noconfirm lvsk-calendar
fi

echo ""
echo "lvsk-calendar fully removed. waycal remains as the clock calendar."
