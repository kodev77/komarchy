#!/usr/bin/env bash
# retro: install linapple (Apple II/II+ emulator, Linux port of AppleWin).
# Boots .dsk disk images from the terminal: `linapple -d1 disk.dsk`.
# Uses the linapple-git AUR package (the only surviving variant — the
# linapple-pie fork has been removed from AUR).
set -euo pipefail

if pacman -Qi linapple-git &>/dev/null || pacman -Qi linapple &>/dev/null; then
  echo "linapple already installed"
  exit 0
fi

echo "installing linapple-git via AUR..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm linapple-git
elif command -v yay &>/dev/null; then
  yay -S --noconfirm linapple-git
else
  echo "no aur helper found (paru/yay), cannot install linapple-git"
  exit 1
fi

# verify — yay/paru return 0 even when the AUR lookup finds nothing
if ! pacman -Qi linapple-git &>/dev/null; then
  echo "linapple-git did not install (AUR lookup may have failed)"
  echo "verify with: yay -Ss linapple"
  exit 1
fi
echo "linapple-git installed"

# Workaround: the linapple-git PKGBUILD has a DESTDIR bug that places files
# at /usr/usr/local/* instead of /usr/local/*. Symlink to the canonical
# locations so `linapple` is on PATH and finds its config + Master.dsk.
if [[ -x /usr/usr/local/bin/linapple && ! -e /usr/local/bin/linapple ]]; then
  echo "patching install paths (PKGBUILD DESTDIR bug)..."
  sudo mkdir -p /usr/local/bin /usr/local/etc /usr/local/share
  sudo ln -sf /usr/usr/local/bin/linapple        /usr/local/bin/linapple
  sudo ln -sf /usr/usr/local/etc/linapple        /usr/local/etc/linapple
  sudo ln -sf /usr/usr/local/share/linapple      /usr/local/share/linapple
  echo "symlinked /usr/local/{bin,etc,share}/linapple"
fi

# final sanity check
if ! command -v linapple &>/dev/null; then
  echo "linapple binary still not on PATH"
  exit 1
fi

echo ""
echo "run: linapple                         (launch emulator)"
echo "     linapple --d1 disk.dsk           (boot with disk in drive 1)"
echo "     linapple --d1 d1.dsk --d2 d2.dsk (boot with both drives)"
echo "     linapple -b --d1 disk.dsk        (autoboot at startup)"
echo "     linapple -h                      (full options)"
echo "in-app: F2 reset, F4 monitor, F11 save state, F12 load state,"
echo "        Pause toggle pause, Scroll-Lock toggle full speed"
