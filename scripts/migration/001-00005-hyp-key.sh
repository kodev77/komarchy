#!/usr/bin/env bash
# hyprland: hyprland resize keybindings: Super+Alt+arrows
set -euo pipefail

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/bindings.conf" ]]; then
  echo "bindings.conf not found, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko komarchy keybinds ---' "$HYPR/bindings.conf"; then
  echo "keybinds already configured, skipping"
  exit 0
fi

echo "patching bindings.conf..."

cat >> "$HYPR/bindings.conf" << 'EOF'

# --- BEGIN ko komarchy keybinds ---

# Resize windows
bindd = SUPER ALT, left, Resize left, resizeactive, -40 0
bindd = SUPER ALT, right, Resize right, resizeactive, 40 0
bindd = SUPER ALT, up, Resize up, resizeactive, 0 -40
bindd = SUPER ALT, down, Resize down, resizeactive, 0 40

# --- END ko komarchy keybinds ---
EOF

echo "bindings.conf patched"
