#!/usr/bin/env bash
# retro: install ACME (cross-assembler for 6502/6510/65c02/65816).
# Assembles .asm source for Apple II, C64, NES, etc. into raw binaries
# that disk-image tools (AppleCommander, c1541) can pack onto media.
# Uses the official Arch `extra/acme` package — no AUR helper needed.
set -euo pipefail

if pacman -Qi acme &>/dev/null; then
  echo "acme already installed ($(acme --version 2>&1 | head -1))"
  exit 0
fi

# Heads-up: acme conflicts with plan9port (which ships its own `acme` editor).
# Bail early with a clear message rather than letting pacman's prompt surprise.
if pacman -Qi plan9port &>/dev/null; then
  echo "plan9port is installed and conflicts with acme (both provide /usr/bin/acme)"
  echo "remove plan9port first or skip this migration"
  exit 1
fi

echo "installing acme from extra repo..."
sudo pacman -S --needed --noconfirm acme

# verify
if ! command -v acme &>/dev/null; then
  echo "acme binary not on PATH after install"
  exit 1
fi
echo "acme installed: $(acme --version 2>&1 | head -1)"

echo ""
echo "run: acme -o out.bin src.asm                  (basic assembly, raw binary)"
echo "     acme -f plain -o out.bin src.asm         (no header — Apple II via AppleCommander)"
echo "     acme -f cbm   -o out.prg src.asm         (2-byte load addr — Commodore PRG)"
echo "     acme -l list.txt -r report.txt \\"
echo "          -o out.bin src.asm                  (listing + symbol report)"
echo "     acme --cpu 6502 -o out.bin src.asm       (pin CPU; also: 65c02, 65816, 6510)"
echo "     acme --help                              (full options)"
echo ""
echo "library macros live under /usr/share/acme/ (e.g. 6502/, cbm/)."
echo "to !source from there, export ACME=/usr/share/acme in your shell rc."
