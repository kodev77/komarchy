#!/usr/bin/env bash
# updates: rollback teams-for-linux idle-away hypridle hook
set -euo pipefail

TFL_CONFIG="$HOME/.config/teams-for-linux/config.json"
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
AUTOSTART_CONF="$HOME/.config/hypr/autostart.conf"
MARKER_BEGIN="# --- komarchy teams idle (018-00084) ---"
MARKER_END="# --- end komarchy teams idle ---"

changed=false

# --- 1. Remove idle-related keys from teams-for-linux config ---
if [[ -f "$TFL_CONFIG" ]] && command -v jq &>/dev/null; then
  if jq -e '.awayOnSystemIdle or .idleDetection' "$TFL_CONFIG" >/dev/null 2>&1; then
    jq 'del(.awayOnSystemIdle) | del(.idleDetection)' "$TFL_CONFIG" > "$TFL_CONFIG.tmp" && mv "$TFL_CONFIG.tmp" "$TFL_CONFIG"
    echo "  teams-for-linux: idle config removed"
    changed=true
  fi
fi

# --- 2. Remove hypridle listener block ---
if [[ -f "$HYPRIDLE_CONF" ]] && grep -qF "$MARKER_BEGIN" "$HYPRIDLE_CONF"; then
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    index($0, begin) { in_block = 1; next }
    in_block && index($0, end) { in_block = 0; next }
    in_block { next }
    { print }
  ' "$HYPRIDLE_CONF" > "$HYPRIDLE_CONF.tmp" && mv "$HYPRIDLE_CONF.tmp" "$HYPRIDLE_CONF"
  echo "  hypridle.conf: teams idle listener removed"

  if pgrep -x hypridle >/dev/null 2>&1; then
    pkill -x hypridle 2>/dev/null || true
    for _ in 1 2 3; do
      pgrep -x hypridle >/dev/null 2>&1 || break
      sleep 1
    done
    pkill -9 -x hypridle 2>/dev/null || true
  fi
  if command -v uwsm-app >/dev/null 2>&1; then
    (uwsm-app -- hypridle >/dev/null 2>&1 & disown) 2>/dev/null || true
  else
    (setsid nohup hypridle >/dev/null 2>&1 </dev/null & disown) 2>/dev/null || true
  fi
  echo "  hypridle: restarted"
  changed=true
fi

# --- 3. Remove autostart hypridle-restart hook ---
if [[ -f "$AUTOSTART_CONF" ]] && grep -qF "$MARKER_BEGIN" "$AUTOSTART_CONF"; then
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    index($0, begin) { in_block = 1; next }
    in_block && index($0, end) { in_block = 0; next }
    in_block { next }
    { print }
  ' "$AUTOSTART_CONF" > "$AUTOSTART_CONF.tmp" && mv "$AUTOSTART_CONF.tmp" "$AUTOSTART_CONF"
  echo "  autostart.conf: delayed hypridle restart removed"
  changed=true
fi

# --- 4. Remove state file ---
rm -f "/tmp/teams-for-linux-idle-state-$USER"

if ! $changed; then
  echo "  teams idle hook: already rolled back"
  exit 0
fi

echo ""
echo "done. restart teams-for-linux to apply:"
echo "  pkill -f teams-for-linux && teams-for-linux &"
