#!/usr/bin/env bash
# updates: rollback ROG control stack — disable services, remove packages.
# Safe to run on non-ASUS hosts (no-op).
set -euo pipefail

SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
if [[ "$SYS_VENDOR" != *ASUS* ]]; then
  echo "not an ASUS host, nothing to roll back"
  exit 0
fi

# --- disable services first ---
for svc in supergfxd asusd; do
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    echo "disabling $svc..."
    sudo systemctl disable --now "$svc"
  else
    echo "$svc not enabled"
  fi
done

# --- remove packages (reverse dependency order: GUI before CLI) ---
PKGS=(rog-control-center supergfxctl asusctl)
TO_REMOVE=()
for p in "${PKGS[@]}"; do
  pacman -Qi "$p" &>/dev/null && TO_REMOVE+=("$p")
done

if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
  echo "removing: ${TO_REMOVE[*]}"
  sudo pacman -Rns --noconfirm "${TO_REMOVE[@]}"
else
  echo "ROG packages not installed"
fi

# --- remove /etc/asusd if empty (we created it; pacman doesn't track it) ---
if [[ -d /etc/asusd ]]; then
  if sudo rmdir /etc/asusd 2>/dev/null; then
    echo "removed empty /etc/asusd"
  else
    echo "/etc/asusd not empty, leaving in place"
  fi
fi
