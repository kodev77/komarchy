#!/usr/bin/env bash
# retro-emu: rollback SimCity Classic 1989 launcher.
# Note: dosbox.linux.conf in repository1-c is *not* removed — it's content
# of the games repo, not host setup.
set -euo pipefail

LAUNCHER="$HOME/.local/bin/simcity-1989"

if [[ -f "$LAUNCHER" ]]; then
  rm -f "$LAUNCHER"
  echo "removed $LAUNCHER"
else
  echo "$LAUNCHER not present"
fi
