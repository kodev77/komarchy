#!/usr/bin/env bash
# bm-tool: full clean-slate rollback — removes the entire bm state
# dir (chromium profile, UI state). Pair with 019's rollback to return
# to a fresh-user baseline. saved-tabs.json is intentionally not
# touched: it lives in the repo working tree as the cross-machine sync
# source of truth, so wiping it would destroy git-tracked data.
set -euo pipefail

BM_STATE_DIR="$HOME/.config/bm"

# Full wipe of bm state — chromium profile, UI state files, everything
# 019 intentionally preserved. Only runs during a deliberate "Rollback
# All" pass, so the fast rollback→migrate dev loop is unaffected.
if [[ -d "$BM_STATE_DIR" ]]; then
  rm -rf "$BM_STATE_DIR"
  echo "  bm state/profile dir: removed ($BM_STATE_DIR)"
else
  echo "  bm state/profile dir: not present, skipping"
fi
