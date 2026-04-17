#!/usr/bin/env bash
# teams: rollback XDG_CURRENT_DESKTOP wrapper
set -euo pipefail

WRAPPER="$HOME/.local/bin/teams-for-linux"
MARKER="# komarchy-tfl-sni-wrapper"

if [[ ! -f "$WRAPPER" ]]; then
  echo "no wrapper at $WRAPPER, skipping"
  exit 0
fi

if ! grep -q "$MARKER" "$WRAPPER"; then
  echo "$WRAPPER is not ours (no komarchy marker), leaving alone"
  exit 0
fi

if pgrep -x teams-for-linux >/dev/null 2>&1; then
  echo "  stopping teams-for-linux before removing wrapper..."
  pkill -f teams-for-linux 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x teams-for-linux >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f teams-for-linux 2>/dev/null || true
  sleep 1
fi

rm -f "$WRAPPER"
echo "removed $WRAPPER"
