#!/usr/bin/env bash
# bm-tool-om37: rollback - restore unpatched bm from repo, strip any leftover
# om37 windowrule sentinel block (deprecated; older migration versions added one).
set -euo pipefail

LOOKFEEL="$HOME/.config/hypr/looknfeel.conf"
BM_SRC="$REPO_DIR/files/local/bin/bm"
BM_DST="$HOME/.local/bin/bm"

BEGIN="# --- BEGIN ko komarchy bm-tool om37 sidebar ---"
END="# --- END ko komarchy bm-tool om37 sidebar ---"
if [[ -f "$LOOKFEEL" ]] && grep -qF "$BEGIN" "$LOOKFEEL"; then
  sed -i "/$BEGIN/,/$END/d" "$LOOKFEEL"
  echo "removed bm-tool om37 sidebar rules"
fi

if [[ -f "$BM_SRC" ]]; then
  install -m 0755 "$BM_SRC" "$BM_DST"
  echo "restored bm from $BM_SRC"
else
  echo "warning: $BM_SRC not found, bm not restored"
fi

if command -v hyprctl &>/dev/null && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  hyprctl reload >/dev/null && echo "hyprland reloaded"
fi
