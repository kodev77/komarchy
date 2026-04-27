#!/usr/bin/env bash
# retro: install AppleCommander (Apple II disk-image manipulator).
# Pairs with acme: acme assembles to a raw .bin, AppleCommander packs that
# .bin into a .dsk floppy image that linapple can boot.
# Uses the AUR `applecommander` package (v13.0+) — the only Linux build path.
set -euo pipefail

if pacman -Qi applecommander &>/dev/null; then
  echo "applecommander already installed"
  exit 0
fi

# Build-time JDK constraint: the PKGBUILD pins gradle to JDK 21-24 (Gradle
# 8.14.2 can't compile against Java 25+ class files). If no in-range JDK
# is installed, fetch jdk21-openjdk (the LTS in that window) — extra repo,
# coexists with whatever default JDK is set, only used during this build.
if [[ -z "$(archlinux-java-run -a 21 -b 24 -f jdk -j 2>/dev/null || true)" ]]; then
  echo "no JDK in [21,24] range found — installing jdk21-openjdk for the build..."
  sudo pacman -S --needed --noconfirm jdk21-openjdk
fi

# `archlinux-java-run` (used by the PKGBUILD) refuses to pick a JDK if no
# default is set system-wide — even with a compatible JDK installed.
# After packages get removed/upgraded the default symlink can vanish.
# Pick java-21-openjdk as default if nothing is currently set.
if archlinux-java status 2>&1 | grep -q "No Java environment set as default"; then
  if archlinux-java status 2>&1 | grep -q "java-21-openjdk"; then
    echo "no default JDK set — pointing archlinux-java at java-21-openjdk..."
    sudo archlinux-java set java-21-openjdk
  fi
fi

echo "installing applecommander via AUR..."
if command -v paru &>/dev/null; then
  paru -S --noconfirm applecommander
elif command -v yay &>/dev/null; then
  yay -S --noconfirm applecommander
else
  echo "no aur helper found (paru/yay), cannot install applecommander"
  exit 1
fi

# verify — yay/paru return 0 even when the AUR lookup finds nothing
if ! pacman -Qi applecommander &>/dev/null; then
  echo "applecommander did not install (AUR lookup may have failed)"
  echo "verify with: yay -Ss applecommander"
  exit 1
fi

# final sanity check: the legacy CLI wrapper must be on PATH
if ! command -v applecommander-ac &>/dev/null; then
  echo "applecommander-ac binary not on PATH after install"
  exit 1
fi
echo "applecommander installed"

echo ""
echo "three CLIs ship in this package:"
echo "  applecommander-ac    legacy CLI (drop-in for the old 1.8.0 jar)"
echo "  applecommander-acx   modern Picocli CLI (subcommands: ls, get, put...)"
echo "  applecommander-gui   GTK graphical disk browser"
echo ""
echo "common (legacy) recipes:"
echo "  applecommander-ac -dos140 disk.dsk                    (create blank DOS 3.3 disk)"
echo "  applecommander-ac -l disk.dsk                         (list catalog)"
echo "  applecommander-ac -p disk.dsk HELLO B 0x300 < hello.bin"
echo "                                                        (put binary, type B, load \$300)"
echo "  applecommander-ac -d disk.dsk HELLO                   (delete file from disk)"
echo "  applecommander-ac --help                              (full options)"
