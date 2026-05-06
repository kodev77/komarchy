#!/usr/bin/env bash
# retro-emu: install `simcity-1994` launcher — runs SimCity Classic (1994
# reissue) via dosbox-staging using dosbox.linux.conf checked in alongside the
# game in repository1-c. Game uses svga_s3 + sb16 + dynamic core (heavier than
# the 1989 original).
set -euo pipefail

if ! pacman -Qi dosbox-staging &>/dev/null; then
  echo "dosbox-staging not installed (run 024-00131-dbx-ins first), skipping"
  exit 2
fi

GAME_DIR="$HOME/repo/repository1-c/L3/retro/gaming/SimCity Games/DOSBox - SimCity Classic - 1994"
if [[ ! -d "$GAME_DIR" ]]; then
  echo "game folder not found: $GAME_DIR"
  exit 2
fi
if [[ ! -f "$GAME_DIR/dosbox.linux.conf" ]]; then
  echo "dosbox.linux.conf not found in $GAME_DIR (commit it in repository1-c)"
  exit 2
fi

BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/simcity-1994"
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# komarchy: launch SimCity Classic (1994 reissue) via dosbox-staging.
# (the dosbox-staging package installs its binary as /usr/bin/dosbox)
#
# Usage:
#   simcity-1994              play the game
#   simcity-1994 --setup      run SETTINGS.EXE (audio/graphics config) — once
set -euo pipefail
cd "$GAME_DIR"
if [[ "\${1:-}" == "--setup" ]]; then
  exec dosbox -conf dosbox.linux.conf -noautoexec \\
    -c "mount c SimCityC" \\
    -c "c:" \\
    -c "SETTINGS.EXE" \\
    -c "exit"
fi
exec dosbox -conf dosbox.linux.conf "\$@"
EOF
chmod +x "$LAUNCHER"
echo "wrote $LAUNCHER"

echo ""
echo "run: simcity-1994                  (launch SimCity Classic 1994 reissue)"
echo "     simcity-1994 --setup          (configure audio/graphics — once)"
