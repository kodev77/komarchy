#!/usr/bin/env bash
# libre: NVIDIA Hyprland env vars (only on machines with NVIDIA GPU)
set -euo pipefail

if ! lspci 2>/dev/null | grep -qi nvidia; then
  echo "no NVIDIA GPU detected, skipping"
  exit 2
fi

HYPR="$HOME/.config/hypr"

if [[ ! -f "$HYPR/envs.conf" ]]; then
  echo "envs.conf not found, skipping"
  exit 0
fi

if grep -q 'NVD_BACKEND' "$HYPR/envs.conf"; then
  echo "NVIDIA envs already configured, skipping"
  exit 0
fi

echo "patching envs.conf..."

cat >> "$HYPR/envs.conf" << 'EOF'

# --- BEGIN ko komarchy nvidia ---
# NVIDIA
env = NVD_BACKEND,direct
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
# --- END ko komarchy nvidia ---
EOF

echo "envs.conf patched"
