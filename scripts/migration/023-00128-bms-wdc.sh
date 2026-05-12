#!/usr/bin/env bash
# bm-tool-om37: bm-py listens on hyprland's IPC socket for the closewindow event
# on its own window address and routes Super+W through action_quit (same path
# as the `q` keybind). Workaround for ghostty 1.3+ on hyprland 0.54+: the GTK
# surface is destroyed on close but ghostty doesn't always exit the process,
# so the PTY stays alive and bm-py never receives SIGHUP — the original
# "Super+W -> ghostty exits -> SIGHUP -> _cleanup() -> close_chromium" chain
# breaks at hop #1 and chromium stays open. Listening to hyprland directly
# sidesteps the broken intermediary. Reinstalls the bm uv tool from source.
set -euo pipefail

PKG_SRC="$REPO_DIR/files/local/share/bm"

if [[ ! -f "$PKG_SRC/pyproject.toml" ]]; then
  echo "package source missing at $PKG_SRC" >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not installed — run 019-00109-bms-uvi.sh first" >&2
  exit 1
fi

# --force replaces the existing tool install. Cache clean drops the previously
# built wheel so the new source is actually picked up — uv tool install will
# happily reuse a cached wheel that pre-dates the source change otherwise.
uv cache clean bm >/dev/null 2>&1 || true
uv tool install --force --from "$PKG_SRC" bm
echo "bm-py reinstalled with hyprland window-close watcher"

# Heads-up: any bm-py already running won't pick up the new code until it's
# restarted. Close any existing bm window via `q` (or kill the process) and
# re-trigger Super+Alt+H to spawn the new build.
if pgrep -x bm-py >/dev/null 2>&1; then
  echo ""
  echo "  note: bm-py is currently running with the old build."
  echo "  press 'q' inside bm (or kill the process) and re-spawn it with"
  echo "  Super+Alt+H to load the new code."
fi
