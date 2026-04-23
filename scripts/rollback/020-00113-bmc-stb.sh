#!/usr/bin/env bash
# bm-tool: full clean-slate rollback — removes saved-tabs.json AND the
# entire bm state dir (chromium profile, UI state). Pair with 019's
# rollback to return to a fresh-user baseline.
set -euo pipefail

SAVED="$HOME/.config/omarchy/bm/saved-tabs.json"
SAVED_DIR="$HOME/.config/omarchy/bm"
BM_STATE_DIR="$HOME/.config/bm"

if [[ -f "$SAVED" ]]; then
  rm -f "$SAVED"
  echo "  saved-tabs.json: removed ($SAVED)"
else
  echo "  saved-tabs.json: not present, skipping"
fi

if [[ -d "$SAVED_DIR" ]] && [[ -z "$(ls -A "$SAVED_DIR")" ]]; then
  rmdir "$SAVED_DIR"
  echo "  saved-tabs dir: removed (empty)"
fi

# Full wipe of bm state — chromium profile, UI state files, everything
# 019 intentionally preserved. Only runs during a deliberate "Rollback
# All" pass, so the fast rollback→migrate dev loop is unaffected.
if [[ -d "$BM_STATE_DIR" ]]; then
  rm -rf "$BM_STATE_DIR"
  echo "  bm state/profile dir: removed ($BM_STATE_DIR)"
else
  echo "  bm state/profile dir: not present, skipping"
fi
