#!/usr/bin/env bash
# updates: rollback vivaldi install
set -euo pipefail

pkgs=(vivaldi-ffmpeg-codecs vivaldi)
to_remove=()

for pkg in "${pkgs[@]}"; do
  if pacman -Qi "$pkg" &>/dev/null; then
    to_remove+=("$pkg")
  else
    echo "$pkg not installed, skipping"
  fi
done

if [[ ${#to_remove[@]} -eq 0 ]]; then
  exit 0
fi

echo "removing: ${to_remove[*]}"
sudo pacman -Rns --noconfirm "${to_remove[@]}"
echo "vivaldi removed"
