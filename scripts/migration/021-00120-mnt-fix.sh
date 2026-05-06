#!/usr/bin/env bash
# updates: replace v1 monitors block with v2 + extend lid-close to disable eDP-2
set -euo pipefail

MONITORS_CONF="$HOME/.config/hypr/monitors.conf"
BINDINGS_CONF="$HOME/.config/hypr/bindings.conf"
EDP1_TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/internal-monitor-disable.conf"
EDP2_TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/komarchy-edp2-disable.conf"

if [[ ! -f "$MONITORS_CONF" ]]; then
  echo "monitors.conf not found, skipping"
  exit 2
fi

# --- 1. monitors.conf: replace v1 with v2 ---
if grep -q '^# --- BEGIN ko komarchy monitors v2 ---$' "$MONITORS_CONF"; then
  echo "monitors v2 already configured"
else
  if grep -q '^# --- BEGIN ko komarchy monitors ---$' "$MONITORS_CONF"; then
    sed -i '/^# --- BEGIN ko komarchy monitors ---$/,/^# --- END ko komarchy monitors ---$/d' "$MONITORS_CONF"
    echo "removed v1 monitors block"
  fi

  cat >> "$MONITORS_CONF" << 'EOF'

# --- BEGIN ko komarchy monitors v2 ---
monitor = desc:ViewSonic Corporation VX3211-2K, preferred, auto, 1
monitor = desc:LG Electronics LG ULTRAGEAR, preferred, auto, 1
# --- END ko komarchy monitors v2 ---
EOF
  echo "monitors.conf patched (v2)"
fi

# --- 2. bindings.conf: lid-switch override (also disable eDP-2) ---
if [[ -f "$BINDINGS_CONF" ]]; then
  if grep -q '^# --- BEGIN ko komarchy lid-switch ---$' "$BINDINGS_CONF"; then
    echo "lid-switch override already configured"
  else
    cat >> "$BINDINGS_CONF" << 'EOF'

# --- BEGIN ko komarchy lid-switch ---
# omarchy 3.6's lid-close template hardcodes eDP-1; this adds eDP-2 disable persistently.
bindl = , switch:on:Lid Switch, exec, echo 'monitor=eDP-2,disable' > $HOME/.local/state/omarchy/toggles/hypr/komarchy-edp2-disable.conf && hyprctl reload
bindl = , switch:off:Lid Switch, exec, rm -f $HOME/.local/state/omarchy/toggles/hypr/komarchy-edp2-disable.conf && hyprctl reload
# --- END ko komarchy lid-switch ---
EOF
    echo "bindings.conf patched (lid-switch)"
  fi
fi

# --- 3. if lid is currently closed (omarchy toggle present), apply eDP-2 disable now ---
if [[ -f "$EDP1_TOGGLE" ]] && [[ ! -f "$EDP2_TOGGLE" ]]; then
  mkdir -p "$(dirname "$EDP2_TOGGLE")"
  echo 'monitor=eDP-2,disable' > "$EDP2_TOGGLE"
  echo "applied eDP-2 disable (lid currently closed)"
fi

# --- 4. reload hyprland ---
if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
