#!/usr/bin/env bash
# retro: install `zork` bash alias — boots Zork I in linapple from any
# directory via the apple2-run wrapper. Disk image lives in the
# 09-KOMARCHY-LINAPPLE project; alias points at its absolute path.
set -euo pipefail

BASHRC="$HOME/.bashrc"
DISK="$HOME/repo/repository1-c/L3/retro/code/AppleWin/source/09-KOMARCHY-LINAPPLE/Zork_I.dsk"

ZRK_BEGIN="# --- BEGIN ko komarchy zork alias ---"
ZRK_END="# --- END ko komarchy zork alias ---"

if [[ ! -f "$BASHRC" ]]; then
  echo "  ~/.bashrc not found, skipping"
  exit 2
fi

if ! command -v apple2-run &>/dev/null; then
  echo "  apple2-run not on PATH — install via 022-00121-lna-cfg.sh first"
  exit 2
fi

if [[ ! -f "$DISK" ]]; then
  echo "  zork disk not found at $DISK"
  echo "  put a Zork .dsk at that location and rerun, or edit DISK in this script"
  exit 2
fi

if grep -qF "$ZRK_BEGIN" "$BASHRC"; then
  echo "  ~/.bashrc: already patched"
else
  cat >> "$BASHRC" <<EOF

$ZRK_BEGIN
# Boot Zork I in linapple. Pass through extra args (scale + linapple flags):
#   zork           - default 2.0x scale
#   zork 3         - 3.0x scale
#   zork 2.5 -f    - 2.5x + linapple's own fullscreen
alias zork='apple2-run "$DISK"'
$ZRK_END
EOF
  echo "  ~/.bashrc: zork alias added"
fi

echo ""
echo "open a new terminal (or run: source ~/.bashrc) to use the alias"
echo "use: zork           (default 2.0x)"
echo "     zork 3         (3.0x scale)"
