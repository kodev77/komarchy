#!/usr/bin/env bash
# bm-tool-om37: rollback the hyprland-IPC window-close watcher. Drops the
# uv cache and reinstalls bm-py from the current repo source. NOTE: this is
# a no-op against repo source — to actually undo the watcher feature, revert
# the tui.py changes in /home/ko/repo/komarchy/files/local/share/bm/bm/tui.py
# (e.g. via `git checkout`) BEFORE running this rollback. Without that, the
# rollback rebuilds bm-py from the watcher-enabled source and behavior is
# unchanged.
set -euo pipefail

PKG_SRC="$REPO_DIR/files/local/share/bm"

if [[ ! -f "$PKG_SRC/pyproject.toml" ]]; then
  echo "package source missing at $PKG_SRC" >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not installed, skipping" >&2
  exit 0
fi

uv cache clean bm >/dev/null 2>&1 || true
uv tool install --force --from "$PKG_SRC" bm
echo "bm-py reinstalled from $PKG_SRC"

if pgrep -x bm-py >/dev/null 2>&1; then
  echo ""
  echo "  note: bm-py is currently running. Press 'q' inside bm and"
  echo "  re-spawn with Super+Alt+H to load the rolled-back code."
fi
