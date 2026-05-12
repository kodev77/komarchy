#!/usr/bin/env bash
# bm-tool-om37: rollback the focus fix. Reinstalls clean repo bm (which has
# neither the focus fix nor the om37 resize patch), then re-applies the
# 023-00125 om37 resize patch so we land in the post-023-00125 state. Does NOT
# resurrect the orphan ghostty processes the migration killed (one-way cleanup).
set -euo pipefail

BM_SRC="$REPO_DIR/files/local/bin/bm"
BM_DST="$HOME/.local/bin/bm"

if [[ ! -f "$BM_SRC" ]]; then
  echo "warning: $BM_SRC not found, skipping bm restore"
  exit 0
fi

install -m 0755 "$BM_SRC" "$BM_DST"
echo "restored bm from $BM_SRC"

if [[ -f "$MIGRATIONS_DIR/023-00125-bms-flt.sh" ]]; then
  echo "re-applying 023-00125 om37 resize patch..."
  bash "$MIGRATIONS_DIR/023-00125-bms-flt.sh"
fi

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
