#!/usr/bin/env bash
# updates: make teams-for-linux auto-set away on idle via hypridle hook (Wayland workaround)
set -euo pipefail

TFL_CONFIG="$HOME/.config/teams-for-linux/config.json"
HYPRIDLE_CONF="$HOME/.config/hypr/hypridle.conf"
AUTOSTART_CONF="$HOME/.config/hypr/autostart.conf"
MARKER_BEGIN="# --- komarchy teams idle (018-00084) ---"
MARKER_END="# --- end komarchy teams idle ---"
IDLE_TIMEOUT=840  # 14 minutes (fires just before omarchy's 15-min screensaver)

# --- 1. Enable awayOnSystemIdle + forceState idle workaround in teams-for-linux config ---
if [[ ! -f "$TFL_CONFIG" ]]; then
  echo "teams-for-linux config.json not found (run 018-00083 first), skipping"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "jq not installed, skipping"
  exit 0
fi

current_force_state=$(jq -r '.idleDetection.forceState // false' "$TFL_CONFIG")
current_away=$(jq -r '.awayOnSystemIdle // false' "$TFL_CONFIG")

if [[ "$current_force_state" != "true" || "$current_away" != "true" ]]; then
  jq --arg user "$USER" '. + {
    awayOnSystemIdle: true,
    idleDetection: {
      forceState: true,
      stateFile: ("/tmp/teams-for-linux-idle-state-" + $user)
    }
  }' "$TFL_CONFIG" > "$TFL_CONFIG.tmp" && mv "$TFL_CONFIG.tmp" "$TFL_CONFIG"
  echo "  teams-for-linux: awayOnSystemIdle + forceState idle enabled"
fi

# --- 2. Initialize idle state file as active ---
STATE_FILE="/tmp/teams-for-linux-idle-state-$USER"
echo "active" > "$STATE_FILE"

# --- 3. Add hypridle listener to flip the state file ---
if [[ ! -f "$HYPRIDLE_CONF" ]]; then
  echo "hypridle.conf not found, skipping"
  exit 0
fi

if ! grep -qF "$MARKER_BEGIN" "$HYPRIDLE_CONF"; then
  cat >> "$HYPRIDLE_CONF" <<EOF

$MARKER_BEGIN
listener {
    timeout = $IDLE_TIMEOUT
    on-timeout = echo inactive > /tmp/teams-for-linux-idle-state-\$USER
    on-resume = echo active > /tmp/teams-for-linux-idle-state-\$USER
}
$MARKER_END
EOF
  echo "  hypridle.conf: teams idle listener added (timeout ${IDLE_TIMEOUT}s)"

  # Restart hypridle to pick up the new listener (doesn't support SIGHUP reload)
  # Use uwsm-app if available (matches omarchy autostart), otherwise fall back
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
fi

# --- 4. Hyprland autostart hook to restart hypridle after Wayland is fully ready ---
# hypridle started at boot by omarchy's exec-once sometimes fails to bind idle events.
# Restarting it ~10s into the session ensures the idle notifier protocol is live.
if [[ -f "$AUTOSTART_CONF" ]] && ! grep -qF "$MARKER_BEGIN" "$AUTOSTART_CONF"; then
  cat >> "$AUTOSTART_CONF" <<EOF

$MARKER_BEGIN
exec-once = sh -c 'sleep 10 && echo active > /tmp/teams-for-linux-idle-state-\$USER && pkill -x hypridle 2>/dev/null; uwsm-app -- hypridle'
$MARKER_END
EOF
  echo "  autostart.conf: delayed hypridle restart added"
fi

echo ""
echo "done. restart teams-for-linux to apply:"
echo "  pkill -f teams-for-linux && teams-for-linux &"
echo ""
echo "hypridle autostart hook will kick in on next reboot."
