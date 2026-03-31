#!/usr/bin/env bash
# hyprland: hyprland stacked groupbar for window groups
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/looknfeel.conf" ]]; then
  echo "looknfeel.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko omarchy-setup groupbar ---' "$HYPR/looknfeel.conf"; then
  echo "groupbar already configured, skipping"
  exit 0
fi

echo "patching looknfeel.conf..."

cat >> "$HYPR/looknfeel.conf" << 'EOF'

# --- BEGIN ko omarchy-setup groupbar ---

group {
    groupbar {
        stacked = true
    }
}

# --- END ko omarchy-setup groupbar ---
EOF

echo "looknfeel.conf patched"
