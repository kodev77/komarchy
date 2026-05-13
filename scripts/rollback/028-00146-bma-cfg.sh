#!/usr/bin/env bash
# bm-tool-alc: rollback bm-specific alacritty config.
set -euo pipefail

DST="$HOME/.config/alacritty/bm.toml"

if [[ -f "$DST" ]]; then
  rm -f "$DST"
  echo "  alacritty bm.toml: removed"
else
  echo "  alacritty bm.toml: not present, skipping"
fi
