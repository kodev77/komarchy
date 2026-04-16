#!/usr/bin/env bash
# tmux: rollback tmux-resurrect install
set -euo pipefail

TMUX_CONF="$HOME/.config/tmux/tmux.conf"
PLUGINS_DIR="$HOME/.config/tmux/plugins"
TPM_DIR="$PLUGINS_DIR/tpm"
RESURRECT_DIR="$PLUGINS_DIR/tmux-resurrect"
SENTINEL_BEGIN="# komarchy: tmux-resurrect BEGIN"
SENTINEL_END="# komarchy: tmux-resurrect END"

if [[ -f "$TMUX_CONF" ]] && grep -qF "$SENTINEL_BEGIN" "$TMUX_CONF"; then
  echo "removing tmux-resurrect block from $TMUX_CONF..."
  sed -i "/$SENTINEL_BEGIN/,/$SENTINEL_END/d" "$TMUX_CONF"
else
  echo "no tmux-resurrect block in tmux.conf"
fi

if [[ -d "$RESURRECT_DIR" ]]; then
  rm -rf "$RESURRECT_DIR"
  echo "removed $RESURRECT_DIR"
fi

if [[ -d "$TPM_DIR" ]]; then
  rm -rf "$TPM_DIR"
  echo "removed $TPM_DIR"
fi

if [[ -d "$PLUGINS_DIR" ]] && [[ -z "$(ls -A "$PLUGINS_DIR")" ]]; then
  rmdir "$PLUGINS_DIR"
  echo "removed empty $PLUGINS_DIR"
fi

echo ""
echo "note: saved snapshots at ~/.local/share/tmux/resurrect/ were left untouched"
