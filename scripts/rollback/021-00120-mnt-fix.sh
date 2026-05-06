#!/usr/bin/env bash
# updates: rollback monitors v2 + lid-switch override - restore v1 block
set -euo pipefail

MONITORS_CONF="$HOME/.config/hypr/monitors.conf"
BINDINGS_CONF="$HOME/.config/hypr/bindings.conf"
EDP2_TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/komarchy-edp2-disable.conf"

# --- 1. monitors.conf: remove v2, restore v1 ---
if [[ -f "$MONITORS_CONF" ]]; then
  HAS_V2=false
  HAS_V1=false
  grep -q '^# --- BEGIN ko komarchy monitors v2 ---$' "$MONITORS_CONF" && HAS_V2=true
  grep -q '^# --- BEGIN ko komarchy monitors ---$' "$MONITORS_CONF" && HAS_V1=true

  if $HAS_V2; then
    sed -i '/^# --- BEGIN ko komarchy monitors v2 ---$/,/^# --- END ko komarchy monitors v2 ---$/d' "$MONITORS_CONF"
    echo "removed v2 monitors block"
  fi

  if ! $HAS_V1; then
    cat >> "$MONITORS_CONF" << 'EOF'

# --- BEGIN ko komarchy monitors ---

# ViewSonic 32" 1440p (HDMI)
monitor = desc:ViewSonic Corporation VX3276 Series, 2560x1440@60, 0x0, 1
monitor = eDP-2, 2560x1600@240, 0x0, 1.6, mirror, desc:ViewSonic Corporation VX3276 Series

# LG ULTRAGEAR 32" 4K (HDMI)
monitor = desc:LG Electronics LG ULTRAGEAR, 2560x1440@59.95, 0x0, 1
monitor = eDP-1, 2880x1800@60, 0x0, 2, mirror, desc:LG Electronics LG ULTRAGEAR

# fallback for any other display
monitor = , preferred, auto, auto

# --- END ko komarchy monitors ---
EOF
    echo "restored v1 monitors block"
  fi
fi

# --- 2. bindings.conf: remove lid-switch override ---
if [[ -f "$BINDINGS_CONF" ]] && grep -q '^# --- BEGIN ko komarchy lid-switch ---$' "$BINDINGS_CONF"; then
  sed -i '/^# --- BEGIN ko komarchy lid-switch ---$/,/^# --- END ko komarchy lid-switch ---$/d' "$BINDINGS_CONF"
  echo "removed lid-switch override"
fi

# --- 3. remove komarchy edp2 toggle file ---
rm -f "$EDP2_TOGGLE"

# --- 4. reload hyprland ---
if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
