#!/usr/bin/env bash
# retro: rollback linapple emulator install
set -euo pipefail

# Remove symlinks created to work around the linapple-git PKGBUILD DESTDIR bug.
# Only delete if they actually point into the broken /usr/usr/local/ tree.
for link in /usr/local/bin/linapple /usr/local/etc/linapple /usr/local/share/linapple; do
  if [[ -L "$link" ]] && [[ "$(readlink "$link")" == /usr/usr/local/* ]]; then
    echo "removing symlink $link"
    sudo rm -f "$link"
  fi
done

if pacman -Qi linapple-git &>/dev/null; then
  echo "removing linapple-git..."
  sudo pacman -Rns --noconfirm linapple-git
  echo "linapple-git removed"
elif pacman -Qi linapple &>/dev/null; then
  echo "removing linapple..."
  sudo pacman -Rns --noconfirm linapple
  echo "linapple removed"
else
  echo "linapple not installed, skipping"
fi
