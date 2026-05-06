#!/usr/bin/env bash
# updates: focus workspace 1 on Hyprland session start. When the laptop boots
# with the lid closed (or any time the internal eDP is disabled at boot),
# Hyprland's default workspace-to-monitor bindings can leave focus on
# workspace 2 instead of 1. An exec-once dispatcher flips it back to 1 once
# Hyprland is fully up. Idempotent — re-running on a host where the marker
# block exists is a no-op.
set -euo pipefail

AUTOSTART="$HOME/.config/hypr/autostart.conf"
if [[ ! -f "$AUTOSTART" ]]; then
  echo "hyprland autostart.conf not found, skipping"
  exit 2
fi

if grep -q '^# --- komarchy workspace-default ---$' "$AUTOSTART"; then
  echo "workspace-default exec-once already present"
else
  cat >> "$AUTOSTART" << 'EOF'

# --- komarchy workspace-default ---
# Wait a bit for monitors + autostart windows to settle, then force the
# active monitor onto workspace 1 (focusworkspaceoncurrentmonitor handles
# the case where workspace 1 was bound to a now-disabled internal display).
exec-once = sh -c 'sleep 3 && hyprctl dispatch focusworkspaceoncurrentmonitor 1'
# --- end komarchy workspace-default ---
EOF
  echo "added 'focusworkspaceoncurrentmonitor 1' exec-once to autostart.conf"
fi

# reload hypr if running (note: exec-once doesn't re-fire on reload — the
# new dispatch happens on next Hyprland startup / session login).
if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
