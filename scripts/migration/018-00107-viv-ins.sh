#!/usr/bin/env bash
# updates: install vivaldi (chromium-based browser with workspaces and sync)
set -euo pipefail

pkgs=(vivaldi vivaldi-ffmpeg-codecs)
to_install=()

for pkg in "${pkgs[@]}"; do
  if pacman -Qi "$pkg" &>/dev/null; then
    echo "$pkg already installed"
  else
    to_install+=("$pkg")
  fi
done

if [[ ${#to_install[@]} -eq 0 ]]; then
  exit 0
fi

echo "installing: ${to_install[*]}"
sudo pacman -S --noconfirm --needed "${to_install[@]}"
echo "vivaldi installed"

echo ""
echo "launch from walker/app-menu or run: vivaldi"
echo "sign in under Settings > Sync to sync workspaces and tabs"
