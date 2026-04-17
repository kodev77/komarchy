#!/usr/bin/env bash
# teams: install a ~/.local/bin wrapper that spoofs XDG_CURRENT_DESKTOP=Unity
# so Electron's appindicator bridge actually exports the tray icon via SNI on Hyprland
set -euo pipefail

REAL_BIN="/usr/bin/teams-for-linux"
WRAPPER="$HOME/.local/bin/teams-for-linux"
MARKER="# komarchy-tfl-sni-wrapper"

if [[ ! -x "$REAL_BIN" ]]; then
  echo "teams-for-linux not installed at $REAL_BIN, skipping"
  exit 2
fi

# refuse to shadow if something other than our wrapper already sits at ~/.local/bin
if [[ -e "$WRAPPER" ]] && ! grep -q "$MARKER" "$WRAPPER"; then
  echo "unrecognized file at $WRAPPER — refusing to overwrite"
  exit 1
fi

# stop teams so the next launch goes through the new wrapper
if pgrep -x teams-for-linux >/dev/null 2>&1; then
  echo "  stopping teams-for-linux so the next launch picks up the wrapper..."
  pkill -f teams-for-linux 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x teams-for-linux >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f teams-for-linux 2>/dev/null || true
  sleep 1
fi

mkdir -p "$(dirname "$WRAPPER")"

cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
# komarchy-tfl-sni-wrapper
# Electron's Linux tray uses libayatana-appindicator, which only activates for
# desktops it recognizes (KDE/Unity/GNOME). Hyprland isn't on that list, so
# StatusNotifierItem never registers and waybar can't render the icon.
# Spoofing XDG_CURRENT_DESKTOP=Unity flips that bridge on.
exec env XDG_CURRENT_DESKTOP=Unity /opt/teams-for-linux/teams-for-linux "$@"
EOF
chmod +x "$WRAPPER"
echo "  installed $WRAPPER"

# sanity check: ~/.local/bin must come before /usr/bin in PATH, otherwise the wrapper
# never wins the shell resolution and walker/hyprctl launches still hit the real binary
if ! echo "$PATH" | tr ':' '\n' | awk -v home="$HOME" '$0==home"/.local/bin"{found=1; exit} $0=="/usr/bin" && !found{bad=1; exit} END{exit bad}'; then
  echo ""
  echo "WARNING: ~/.local/bin is not before /usr/bin in PATH — wrapper may not take effect"
  echo "         current PATH: $PATH"
fi

echo ""
echo "launch teams-for-linux (run: teams-for-linux &) — tray icon should now register"
