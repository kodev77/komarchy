#!/usr/bin/env bash
# bm-tool-om37: remove obsolete v1/v2 monitor blocks + lid-switch override.
# omarchy 3.7's omarchy-hyprland-monitor-internal detects the active eDP
# dynamically, so the komarchy eDP-2 lid override is no longer needed; the
# desc-pinned monitor blocks are also redundant vs. the default catch-all.
set -euo pipefail

MONITORS_CONF="$HOME/.config/hypr/monitors.conf"
BINDINGS_CONF="$HOME/.config/hypr/bindings.conf"
EDP2_TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/komarchy-edp2-disable.conf"

CHANGED=false

if [[ -f "$MONITORS_CONF" ]]; then
  if grep -q '^# --- BEGIN ko komarchy monitors v2 ---$' "$MONITORS_CONF"; then
    sed -i '/^# --- BEGIN ko komarchy monitors v2 ---$/,/^# --- END ko komarchy monitors v2 ---$/d' "$MONITORS_CONF"
    echo "removed v2 monitors block"
    CHANGED=true
  fi

  if grep -q '^# --- BEGIN ko komarchy monitors ---$' "$MONITORS_CONF"; then
    sed -i '/^# --- BEGIN ko komarchy monitors ---$/,/^# --- END ko komarchy monitors ---$/d' "$MONITORS_CONF"
    echo "removed v1 monitors block"
    CHANGED=true
  fi

  if grep -q '^env = GDK_SCALE,1$' "$MONITORS_CONF"; then
    sed -i 's/^env = GDK_SCALE,1$/env = GDK_SCALE,2/' "$MONITORS_CONF"
    echo "restored GDK_SCALE=2"
    CHANGED=true
  fi

  if grep -q '^# monitor=,preferred,auto,auto$' "$MONITORS_CONF"; then
    sed -i 's|^# monitor=,preferred,auto,auto$|monitor=,preferred,auto,auto|' "$MONITORS_CONF"
    echo "restored default monitor line"
    CHANGED=true
  fi
fi

if [[ -f "$BINDINGS_CONF" ]] && grep -q '^# --- BEGIN ko komarchy lid-switch ---$' "$BINDINGS_CONF"; then
  sed -i '/^# --- BEGIN ko komarchy lid-switch ---$/,/^# --- END ko komarchy lid-switch ---$/d' "$BINDINGS_CONF"
  echo "removed lid-switch override"
  CHANGED=true
fi

if [[ -f "$EDP2_TOGGLE" ]]; then
  rm -f "$EDP2_TOGGLE"
  echo "removed komarchy edp2 toggle"
  CHANGED=true
fi

if $CHANGED && command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi

if ! $CHANGED; then
  echo "already clean"
fi
