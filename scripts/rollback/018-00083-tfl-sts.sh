#!/usr/bin/env bash
# updates: rollback teams-for-linux MQTT status publishing + waybar module
set -euo pipefail

WAYBAR_CONFIG="$HOME/.config/waybar/config.jsonc"
WAYBAR_STYLE="$HOME/.config/waybar/style.css"
WAYBAR_STATUS_SCRIPT="$HOME/.config/waybar/scripts/teams-status.sh"
TFL_CONFIG="$HOME/.config/teams-for-linux/config.json"
MOSQUITTO_CONF="/etc/mosquitto/mosquitto.conf"
MARKER_BEGIN="# --- komarchy teams status (018-00083) ---"
MARKER_END="# --- end komarchy teams status ---"
CSS_MARKER_BEGIN="/* --- komarchy teams status (018-00083) --- */"
CSS_MARKER_END="/* --- end komarchy teams status --- */"

# --- 0. Pre-cache sudo so later steps don't prompt mid-script ---
if ! sudo -n true 2>/dev/null; then
  sudo -v
fi

# --- 1. Remove custom/teams from waybar config.jsonc ---
if [[ -f "$WAYBAR_CONFIG" ]] && grep -q '"custom/teams"' "$WAYBAR_CONFIG"; then
  # Remove from modules-right array
  sed -i '/^    "custom\/teams",$/d' "$WAYBAR_CONFIG"

  # Remove module definition block
  awk '
    /^  "custom\/teams": \{/ { in_block = 1; next }
    in_block && /^  \},$/ { in_block = 0; next }
    in_block { next }
    { print }
  ' "$WAYBAR_CONFIG" > "$WAYBAR_CONFIG.tmp" && mv "$WAYBAR_CONFIG.tmp" "$WAYBAR_CONFIG"
  echo "  waybar config.jsonc: custom/teams removed"
fi

# --- 2. Remove CSS block (supports both shell-style and CSS-style markers) ---
if [[ -f "$WAYBAR_STYLE" ]] && ( grep -qF "$CSS_MARKER_BEGIN" "$WAYBAR_STYLE" || grep -qF "$MARKER_BEGIN" "$WAYBAR_STYLE" ); then
  awk -v sb="$MARKER_BEGIN" -v se="$MARKER_END" -v cb="$CSS_MARKER_BEGIN" -v ce="$CSS_MARKER_END" '
    index($0, cb) || index($0, sb) { in_block = 1; next }
    in_block && (index($0, ce) || index($0, se)) { in_block = 0; next }
    in_block { next }
    { print }
  ' "$WAYBAR_STYLE" > "$WAYBAR_STYLE.tmp" && mv "$WAYBAR_STYLE.tmp" "$WAYBAR_STYLE"
  echo "  waybar style.css: teams status colors removed"
fi

# --- 3. Remove waybar script ---
if [[ -f "$WAYBAR_STATUS_SCRIPT" ]]; then
  rm -f "$WAYBAR_STATUS_SCRIPT"
  echo "  waybar: teams-status.sh removed"
fi

# --- 4. Remove MQTT + cacheManagement blocks from teams-for-linux config ---
if [[ -f "$TFL_CONFIG" ]] && ( grep -q '"mqtt"' "$TFL_CONFIG" || grep -q '"cacheManagement"' "$TFL_CONFIG" ); then
  if command -v jq &>/dev/null; then
    # Drop both keys added by this migration
    jq 'del(.mqtt) | del(.cacheManagement) | del(.trayIconEnabled)' "$TFL_CONFIG" > "$TFL_CONFIG.tmp" && mv "$TFL_CONFIG.tmp" "$TFL_CONFIG"
    # If the file now has only an empty object, remove it
    if [[ "$(jq -r 'keys | length' "$TFL_CONFIG" 2>/dev/null)" == "0" ]]; then
      rm -f "$TFL_CONFIG"
    fi
  fi
  echo "  teams-for-linux: MQTT + cache management config removed"
fi

# --- 5. Remove mosquitto listener config block ---
if sudo grep -qF "$MARKER_BEGIN" "$MOSQUITTO_CONF"; then
  sudo awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    index($0, begin) { in_block = 1; next }
    in_block && index($0, end) { in_block = 0; next }
    in_block { next }
    { print }
  ' "$MOSQUITTO_CONF" | sudo tee "$MOSQUITTO_CONF.tmp" > /dev/null
  sudo mv "$MOSQUITTO_CONF.tmp" "$MOSQUITTO_CONF"
  sudo systemctl restart mosquitto.service 2>/dev/null || true
  echo "  mosquitto.conf: listener block removed"
fi

# --- 6. Disable mosquitto service (leave package installed) ---
if systemctl is-enabled mosquitto.service &>/dev/null; then
  sudo systemctl disable --now mosquitto.service
  echo "  mosquitto.service: disabled and stopped"
fi

# --- 7. Reload waybar ---
pkill -SIGUSR2 waybar 2>/dev/null || true

echo ""
echo "rollback complete. note: mosquitto/jq packages remain installed."
echo "remove manually if desired:  sudo pacman -Rns mosquitto jq"
