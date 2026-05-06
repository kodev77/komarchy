#!/usr/bin/env bash
# updates: install ROG control stack (asusctl + rog-control-center + supergfxctl)
# and enable asusd/supergfxd. Guarded to ASUS ROG hosts only via DMI — exits 2
# (skip) on non-ROG machines so the migration can live in a shared repo.
# Provides:
#   rog-control-center  GUI: profiles, fan curves, LEDs, GPU mode
#   asusctl             CLI for platform_profile + AURA/AniMe
#   supergfxctl         GPU mode switch (hybrid / integrated / dedicated)
set -euo pipefail

# --- guard: ASUS ROG only ---
SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
PRODUCT_FAMILY=$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)

if [[ "$SYS_VENDOR" != *ASUS* ]]; then
  echo "not an ASUS host (sys_vendor='$SYS_VENDOR'), skipping"
  exit 2
fi

if [[ "$PRODUCT_FAMILY" != *ROG* && "$PRODUCT_NAME" != *ROG* ]]; then
  echo "not an ASUS ROG host (family='$PRODUCT_FAMILY', product='$PRODUCT_NAME'), skipping"
  exit 2
fi

echo "detected ASUS ROG host: ${PRODUCT_NAME:-$PRODUCT_FAMILY}"

# --- install missing packages ---
PKGS=(asusctl rog-control-center supergfxctl)
MISSING=()
for p in "${PKGS[@]}"; do
  pacman -Qi "$p" &>/dev/null || MISSING+=("$p")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "installing: ${MISSING[*]}"
  sudo pacman -S --needed --noconfirm "${MISSING[@]}"
else
  echo "ROG packages already installed"
fi

# --- prepare runtime dirs ---
# asusd.service's mount namespace references /etc/asusd; the Arch package
# doesn't always create it, leaving the unit failing with status=226/NAMESPACE.
if [[ ! -d /etc/asusd ]]; then
  echo "creating /etc/asusd..."
  sudo install -d -m 0755 /etc/asusd
fi

# --- enable services ---
for svc in asusd supergfxd; do
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    echo "$svc already enabled"
  else
    echo "enabling $svc..."
    sudo systemctl enable --now "$svc"
  fi
done

echo ""
echo "run: rog-control-center               (full GUI)"
echo "     asusctl profile -p               (show current profile)"
echo "     asusctl profile -P Balanced      (set Quiet/Balanced/Performance)"
echo "     supergfxctl -g                   (show current GPU mode)"
