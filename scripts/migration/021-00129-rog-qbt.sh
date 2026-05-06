#!/usr/bin/env bash
# updates: on Hyprland session start, force platform profile to Quiet and pop
# a desktop notification confirming the mode. Works around the asus-armoury /
# asusd race where the firmware default Performance can survive boot. Guarded
# to ASUS ROG hosts only. Requires asusctl (021-00128-rog-ins).
set -euo pipefail

# --- guard: ASUS ROG only ---
SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
PRODUCT_FAMILY=$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)

if [[ "$SYS_VENDOR" != *ASUS* ]]; then
  echo "not an ASUS host, skipping"
  exit 2
fi
if [[ "$PRODUCT_FAMILY" != *ROG* && "$PRODUCT_NAME" != *ROG* ]]; then
  echo "not an ASUS ROG host, skipping"
  exit 2
fi

if ! command -v asusctl &>/dev/null; then
  echo "asusctl not installed (run 021-00128-rog-ins first), skipping"
  exit 2
fi

AUTOSTART="$HOME/.config/hypr/autostart.conf"
if [[ ! -f "$AUTOSTART" ]]; then
  echo "hyprland autostart.conf not found, skipping"
  exit 2
fi

BIN_DIR="$HOME/.local/bin"
SCRIPT="$BIN_DIR/komarchy-rog-quiet-boot"

# --- write helper script ---
mkdir -p "$BIN_DIR"
cat > "$SCRIPT" << 'EOF'
#!/usr/bin/env bash
# komarchy: set platform profile to Quiet at session start; notify on result.
# Logs to journal under tag komarchy-rog-quiet-boot
#   journalctl --user -b -t komarchy-rog-quiet-boot
set -euo pipefail

LOG_TAG=komarchy-rog-quiet-boot
log() { logger -t "$LOG_TAG" "$*"; }

log "starting"

# Let mako (notify daemon), asusd, and the user dbus session settle.
sleep 5

# Wait for asusd dbus to be reachable (up to ~10s on top of the 5s sleep).
for _ in {1..40}; do
  asusctl profile get &>/dev/null && break
  sleep 0.25
done

if ! asusctl profile get &>/dev/null; then
  log "asusd unreachable after wait"
  notify-send -u critical -i dialog-error \
    "Power Profile" "asusd not reachable" || true
  exit 1
fi

if asusctl profile set Quiet 2>/dev/null; then
  active=$(asusctl profile get 2>/dev/null | awk -F': ' '/Active/{print $2}')
  log "set Quiet ok, active=$active"
  notify-send -u low -i power-profile-power-saver \
    "Power Profile" "Set to Quiet (active: ${active:-unknown})" || \
      log "notify-send failed"
else
  log "asusctl profile set Quiet FAILED"
  notify-send -u critical -i dialog-error \
    "Power Profile" "Failed to set Quiet mode" || true
  exit 1
fi
EOF
chmod +x "$SCRIPT"
echo "wrote $SCRIPT"

# --- add hyprland exec-once via marker block (idempotent) ---
if grep -q '^# --- komarchy rog-quiet-boot ---$' "$AUTOSTART"; then
  echo "autostart entry already present"
else
  cat >> "$AUTOSTART" << EOF

# --- komarchy rog-quiet-boot ---
exec-once = $SCRIPT
# --- end komarchy rog-quiet-boot ---
EOF
  echo "added exec-once to autostart.conf"
fi

# reload hypr if running
if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
