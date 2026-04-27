#!/usr/bin/env bash
# retro: rollback per-user linapple configs + apple2-run wrapper
set -euo pipefail

USER_CONF_DIR="$HOME/.config/linapple"
WRAPPER="$HOME/.local/bin/apple2-run"

if [[ -f "$WRAPPER" ]]; then
  rm -f "$WRAPPER"
  echo "  removed $WRAPPER"
else
  echo "  not present: $WRAPPER"
fi

if [[ -d "$USER_CONF_DIR" ]]; then
  # only remove files we created (linapple.conf + linapple-*.conf), leave
  # any unrelated files the user may have placed there alone
  rm -f "$USER_CONF_DIR/linapple.conf" "$USER_CONF_DIR"/linapple-*.conf
  echo "  removed config presets in $USER_CONF_DIR"
  if rmdir "$USER_CONF_DIR" 2>/dev/null; then
    echo "  removed empty dir $USER_CONF_DIR"
  else
    echo "  $USER_CONF_DIR not empty, kept"
  fi
else
  echo "  not present: $USER_CONF_DIR"
fi
