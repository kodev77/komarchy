#!/usr/bin/env bash
# hello: rollback hyprland monitor setup
set -euo pipefail

MONITORS_CONF="$HOME/.config/hypr/monitors.conf"

if [[ ! -f "$MONITORS_CONF" ]]; then
  echo "monitors.conf not found, skipping"
  exit 0
fi

if ! grep -q '# --- BEGIN ko komarchy monitors ---' "$MONITORS_CONF"; then
  echo "monitor config not found, skipping"
  exit 0
fi

echo "reverting monitors.conf..."

# Remove the marker block
sed -i '/# --- BEGIN ko komarchy monitors ---/,/# --- END ko komarchy monitors ---/d' "$MONITORS_CONF"

# Restore GDK_SCALE
sed -i 's/^env = GDK_SCALE,1$/env = GDK_SCALE,2/' "$MONITORS_CONF"

# Uncomment the default monitor line
sed -i 's|^# monitor=,preferred,auto,auto$|monitor=,preferred,auto,auto|' "$MONITORS_CONF"

echo "monitors.conf reverted"
