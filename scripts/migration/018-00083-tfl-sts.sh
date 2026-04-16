#!/usr/bin/env bash
# updates: publish teams-for-linux status via local MQTT and show it in waybar
set -euo pipefail

WAYBAR_CONFIG="$HOME/.config/waybar/config.jsonc"
WAYBAR_STYLE="$HOME/.config/waybar/style.css"
WAYBAR_SCRIPTS="$HOME/.config/waybar/scripts"
WAYBAR_STATUS_SCRIPT="$WAYBAR_SCRIPTS/teams-status.sh"
TFL_CONFIG_DIR="$HOME/.config/teams-for-linux"
TFL_CONFIG="$TFL_CONFIG_DIR/config.json"
MOSQUITTO_CONF="/etc/mosquitto/mosquitto.conf"
MARKER_BEGIN="# --- komarchy teams status (018-00083) ---"
MARKER_END="# --- end komarchy teams status ---"
CSS_MARKER_BEGIN="/* --- komarchy teams status (018-00083) --- */"
CSS_MARKER_END="/* --- end komarchy teams status --- */"

# --- 1. Install mosquitto + clients + jq ---
for pkg in mosquitto jq; do
  if ! pacman -Qi "$pkg" &>/dev/null; then
    echo "installing $pkg..."
    sudo pacman -S --needed --noconfirm "$pkg"
  fi
done

# --- 2. Configure mosquitto to listen on localhost only (idempotent) ---
# Ensure the persistence directory exists and is writable by mosquitto user
sudo install -d -o mosquitto -g mosquitto -m 750 /var/lib/mosquitto 2>/dev/null || \
  sudo mkdir -p /var/lib/mosquitto

if ! sudo grep -qF "$MARKER_BEGIN" "$MOSQUITTO_CONF"; then
  echo "configuring mosquitto to listen on 127.0.0.1..."
  sudo tee -a "$MOSQUITTO_CONF" > /dev/null <<EOF

$MARKER_BEGIN
listener 1883 127.0.0.1
allow_anonymous true
persistence true
persistence_location /var/lib/mosquitto/
autosave_interval 30
$MARKER_END
EOF
  sudo systemctl restart mosquitto.service 2>/dev/null || true
fi

# --- 3. Enable and start mosquitto service ---
if ! systemctl is-enabled mosquitto.service &>/dev/null; then
  echo "enabling mosquitto.service..."
  sudo systemctl enable --now mosquitto.service
elif ! systemctl is-active mosquitto.service &>/dev/null; then
  sudo systemctl start mosquitto.service
fi

# --- 4. Write teams-for-linux MQTT config ---
mkdir -p "$TFL_CONFIG_DIR"
if [[ ! -f "$TFL_CONFIG" ]]; then
  cat > "$TFL_CONFIG" <<'EOF'
{
  "mqtt": {
    "enabled": true,
    "brokerUrl": "mqtt://localhost:1883",
    "clientId": "teams-for-linux",
    "topicPrefix": "teams",
    "statusTopic": "status",
    "commandTopic": "",
    "statusCheckInterval": 10000
  },
  "cacheManagement": {
    "enabled": true,
    "maxCacheSizeMB": 600,
    "cacheCheckIntervalMs": 3600000
  },
  "trayIconEnabled": false
}
EOF
  echo "  teams-for-linux: config.json created with MQTT + cache management + tray icon disabled"
else
  # Merge MQTT + cacheManagement into existing config using jq
  jq '. + {
    mqtt: {
      enabled: true,
      brokerUrl: "mqtt://localhost:1883",
      clientId: "teams-for-linux",
      topicPrefix: "teams",
      statusTopic: "status",
      commandTopic: "",
      statusCheckInterval: 10000
    },
    cacheManagement: {
      enabled: true,
      maxCacheSizeMB: 600,
      cacheCheckIntervalMs: 3600000
    },
    trayIconEnabled: false
  }' "$TFL_CONFIG" > "$TFL_CONFIG.tmp" && mv "$TFL_CONFIG.tmp" "$TFL_CONFIG"
  echo "  teams-for-linux: MQTT + cache management + tray icon disabled merged into existing config.json"
fi

# --- 5. Write waybar status script ---
mkdir -p "$WAYBAR_SCRIPTS"
cat > "$WAYBAR_STATUS_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# Polls teams-for-linux status (MQTT retained) + unread count (window title)
# and emits JSON for waybar.
set -u

TOPIC="teams/status"
BROKER="localhost"

emit() {
  local class="$1" text="$2" status_label="$3" count="$4"
  local tooltip alt="$class"
  if [[ "$count" -gt 0 ]]; then
    tooltip="Teams: $status_label · $count unread"
    class="unread"
  else
    tooltip="Teams: $status_label"
  fi
  printf '{"text":"%s","alt":"%s","class":"%s","tooltip":"%s"}\n' \
    "$text" "$alt" "$class" "$tooltip"
}

map_status() {
  local raw="$1" count="$2"
  local key
  key="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '"[:space:]')"
  local text=""

  case "$key" in
    available|online|free)
      emit "available" "$text" "Available" "$count" ;;
    busy|inacall|incall|onthephone|inameeting|inconferencecall|presenting)
      emit "busy" "$text" "Busy" "$count" ;;
    donotdisturb|dnd|focusing)
      emit "dnd" "$text" "Do Not Disturb" "$count" ;;
    away)
      emit "away" "$text" "Away" "$count" ;;
    berightback|brb)
      emit "brb" "$text" "Be Right Back" "$count" ;;
    offline|off|appearoffline|invisible|presenceunknown|unknown|"")
      emit "offline" "$text" "Offline" "$count" ;;
    *)
      emit "unknown" "$text" "$raw" "$count" ;;
  esac
}

get_unread_count() {
  if ! command -v hyprctl &>/dev/null; then
    echo 0; return
  fi
  local title
  title=$(hyprctl clients -j 2>/dev/null \
    | jq -r '.[] | select((.class // "") | test("teams-for-linux"; "i")) | .title' \
    | head -1)
  if [[ "$title" =~ \(([0-9]+)\) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 0
  fi
}

get_status() {
  local payload
  payload=$(mosquitto_sub -h "$BROKER" -t "$TOPIC" -C 1 --retained-only -W 1 2>/dev/null || echo "")
  if [[ -z "$payload" ]]; then
    echo "offline"; return
  fi
  local status
  status=$(echo "$payload" | jq -r '.status // empty' 2>/dev/null || true)
  if [[ -z "$status" ]]; then
    status="$payload"
  fi
  echo "$status"
}

while true; do
  if pgrep -x teams-for-linux >/dev/null 2>&1; then
    status="$(get_status)"
    count="$(get_unread_count)"
  else
    status="offline"
    count=0
  fi
  map_status "$status" "$count"
  sleep 2
done
SCRIPT
chmod +x "$WAYBAR_STATUS_SCRIPT"
echo "  waybar: teams-status.sh installed"

# --- 6. Add custom/teams module + definition to waybar config.jsonc ---
if ! grep -q '"custom/teams"' "$WAYBAR_CONFIG"; then
  # Insert into modules-right (before the first entry, usually "tray")
  awk '
    /^  "modules-right":/ { in_mr = 1 }
    in_mr && /^    "/ && !inserted {
      print "    \"custom/teams\","
      inserted = 1
    }
    in_mr && /^  \],?$/ { in_mr = 0 }
    { print }
  ' "$WAYBAR_CONFIG" > "$WAYBAR_CONFIG.tmp" && mv "$WAYBAR_CONFIG.tmp" "$WAYBAR_CONFIG"

  # Insert module definition before "tray": {
  awk '
    /^  "tray": \{/ && !inserted {
      print "  \"custom/teams\": {"
      print "    \"exec\": \"~/.config/waybar/scripts/teams-status.sh\","
      print "    \"return-type\": \"json\","
      print "    \"format\": \"{icon}{text}\","
      print "    \"format-icons\": {"
      print "      \"available\": \"●\","
      print "      \"busy\": \"●\","
      print "      \"dnd\": \"●\","
      print "      \"away\": \"●\","
      print "      \"brb\": \"●\","
      print "      \"offline\": \"●\","
      print "      \"unknown\": \"●\","
      print "    },"
      print "    \"tooltip\": true,"
      print "    \"on-click\": \"gtk-launch teams-for-linux || teams-for-linux\""
      print "  },"
      inserted = 1
    }
    { print }
  ' "$WAYBAR_CONFIG" > "$WAYBAR_CONFIG.tmp" && mv "$WAYBAR_CONFIG.tmp" "$WAYBAR_CONFIG"
  echo "  waybar config.jsonc: custom/teams module added"
fi

# --- 7. Append CSS for the teams status colors ---
if ! grep -qF "$CSS_MARKER_BEGIN" "$WAYBAR_STYLE"; then
  cat >> "$WAYBAR_STYLE" <<EOF

$CSS_MARKER_BEGIN
#custom-teams { padding: 0 8px; margin-right: 4px; font-size: 22px; }
#custom-teams.available { color: #3adb76; }
#custom-teams.busy      { color: #e23e57; }
#custom-teams.dnd       { color: #a80000; }
#custom-teams.away      { color: #ffae00; }
#custom-teams.brb       { color: #ffae00; }
#custom-teams.offline   { color: #808080; }
#custom-teams.unknown   { color: #808080; }
#custom-teams.unread, #custom-teams.unread label { color: #C77DFF; }
$CSS_MARKER_END
EOF
  echo "  waybar style.css: teams status colors added"
fi

# --- 8. Reload waybar ---
pkill -SIGUSR2 waybar 2>/dev/null || true

echo ""
echo "done."
echo "- restart teams-for-linux so it picks up the new MQTT config"
echo "- check status is publishing:  mosquitto_sub -h localhost -t 'teams/#' -v"
