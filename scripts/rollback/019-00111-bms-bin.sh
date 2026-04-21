#!/usr/bin/env bash
# bm-tool: rollback bm launcher + ghostty config + all user data/caches
set -euo pipefail

DST_BIN="$HOME/.local/bin/bm"
DST_GHOSTTY="$HOME/.config/ghostty/bm.conf"
DST_SAVED_DIR="$HOME/.config/omarchy/bm"
BM_STATE_DIR="$HOME/.config/bm"
BM_CACHE_DIR="$HOME/.cache/bm"

if [[ -f "$DST_BIN" ]]; then
  rm -f "$DST_BIN"
  echo "  bm launcher: removed"
else
  echo "  bm launcher: not present, skipping"
fi

if [[ -f "$DST_GHOSTTY" ]]; then
  rm -f "$DST_GHOSTTY"
  echo "  ghostty bm.conf: removed"
else
  echo "  ghostty bm.conf: not present, skipping"
fi

# Saved-tabs and bm-scoped config dir (state.json, dedicated chromium profile).
# Wiped to give a clean slate — this is a test-cycle rollback, not a
# user-preservation rollback.
if [[ -d "$DST_SAVED_DIR" ]]; then
  rm -rf "$DST_SAVED_DIR"
  echo "  saved-tabs dir: removed ($DST_SAVED_DIR)"
else
  echo "  saved-tabs dir: not present, skipping"
fi

if [[ -d "$BM_STATE_DIR" ]]; then
  rm -rf "$BM_STATE_DIR"
  echo "  bm state/profile dir: removed ($BM_STATE_DIR)"
else
  echo "  bm state/profile dir: not present, skipping"
fi

if [[ -d "$BM_CACHE_DIR" ]]; then
  rm -rf "$BM_CACHE_DIR"
  echo "  bm favicon cache: removed ($BM_CACHE_DIR)"
else
  echo "  bm favicon cache: not present, skipping"
fi
