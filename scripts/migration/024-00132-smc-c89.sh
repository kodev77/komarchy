#!/usr/bin/env bash
# retro-emu: install `simcity-1989` launcher — runs SimCity Classic 1989 via
# dosbox-staging using the dosbox.linux.conf checked in alongside the game in
# repository1-c. Launcher cd's to the game folder so the conf's relative
# `mount c .` resolves to the right place.
set -euo pipefail

if ! pacman -Qi dosbox-staging &>/dev/null; then
  echo "dosbox-staging not installed (run 024-00131-dbx-ins first), skipping"
  exit 2
fi

GAME_DIR="$HOME/repo/repository1-c/L3/retro/gaming/SimCity Games/DOSBox - SimCity Classic - 1989"
if [[ ! -d "$GAME_DIR" ]]; then
  echo "game folder not found: $GAME_DIR"
  exit 2
fi
if [[ ! -f "$GAME_DIR/dosbox.linux.conf" ]]; then
  echo "dosbox.linux.conf not found in $GAME_DIR (commit it in repository1-c)"
  exit 2
fi

BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/simcity-1989"
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# komarchy: launch SimCity Classic 1989 via dosbox-staging
# (the dosbox-staging package installs its binary as /usr/bin/dosbox)
set -euo pipefail
cd "$GAME_DIR"
exec dosbox -conf dosbox.linux.conf "\$@"
EOF
chmod +x "$LAUNCHER"
echo "wrote $LAUNCHER"

echo ""
echo "run: simcity-1989                  (launch SimCity Classic 1989)"
