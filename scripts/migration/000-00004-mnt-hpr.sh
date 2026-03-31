#!/usr/bin/env bash
# hello: hyprland monitor setup: external monitor + laptop mirrored, GDK_SCALE fix
set -euo pipefail

MONITORS_CONF="$HOME/.config/hypr/monitors.conf"

if [[ ! -f "$MONITORS_CONF" ]]; then
  echo "monitors.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko omarchy-setup monitors ---' "$MONITORS_CONF"; then
  echo "monitors already configured, skipping"
  exit 0
fi

# GDK_SCALE 2 → 1
sed -i 's/^env = GDK_SCALE,2$/env = GDK_SCALE,1/' "$MONITORS_CONF"

# Comment out the default monitor line
sed -i 's|^monitor=,preferred,auto,auto$|# monitor=,preferred,auto,auto|' "$MONITORS_CONF"

# Append monitor config with markers
cat >> "$MONITORS_CONF" << 'EOF'

# --- BEGIN ko omarchy-setup monitors ---

# ViewSonic 32" 1440p (HDMI)
monitor = desc:ViewSonic Corporation VX3276 Series, 2560x1440@60, 0x0, 1
monitor = eDP-2, 2560x1600@240, 0x0, 1.6, mirror, desc:ViewSonic Corporation VX3276 Series

# LG ULTRAGEAR 32" 4K (HDMI)
monitor = desc:LG Electronics LG ULTRAGEAR, 2560x1440@59.95, 0x0, 1
monitor = eDP-1, 2880x1800@60, 0x0, 2, mirror, desc:LG Electronics LG ULTRAGEAR

# fallback for any other display
monitor = , preferred, auto, auto

# --- END ko omarchy-setup monitors ---
EOF

echo "monitors.conf patched"
