#!/usr/bin/env bash
# bm-tool: rollback bm launcher + ghostty config + ephemeral caches.
# Preserves chromium profile and saved-tabs.json across fast dev loops;
# full clean-slate wipe happens in 020's rollback.
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

# saved-tabs.json is the user's bookmark data — preserve across fast dev
# cycles. Migration re-seeds only when absent, so leaving it is a no-op
# on re-apply. Full removal happens in 020's rollback.
if [[ -f "$DST_SAVED_DIR/saved-tabs.json" ]]; then
  echo "  saved-tabs.json: preserved ($DST_SAVED_DIR/saved-tabs.json)"
else
  echo "  saved-tabs.json: not present, skipping"
fi

# Ephemeral bm UI state — safe to drop on every rollback. The TUI
# rewrites these on next launch.
for f in "$BM_STATE_DIR/bm.pid" "$BM_STATE_DIR/state.json"; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    echo "  bm ephemeral state: removed ($f)"
  fi
done

# Chromium profile (auth cookies, saved passwords, site permissions,
# history) lives at $BM_STATE_DIR/profile — preserve across fast dev
# cycles so rollback→migrate doesn't re-prompt notification blocks or
# drop logged-in sessions. Full removal happens in 020's rollback.
if [[ -d "$BM_STATE_DIR/profile" ]]; then
  echo "  bm chromium profile: preserved ($BM_STATE_DIR/profile)"
else
  echo "  bm chromium profile: not present, skipping"
fi

if [[ -d "$BM_CACHE_DIR" ]]; then
  rm -rf "$BM_CACHE_DIR"
  echo "  bm favicon cache: removed ($BM_CACHE_DIR)"
else
  echo "  bm favicon cache: not present, skipping"
fi
