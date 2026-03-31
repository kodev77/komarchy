#!/usr/bin/env bash
# hello: remove work-specific git config
set -euo pipefail

if [[ -f "$HOME/.gitconfig.work" ]]; then
  echo "removing gitconfig.work..."
  rm -f "$HOME/.gitconfig.work"
  echo "gitconfig.work removed"
else
  echo "gitconfig.work not found, skipping"
fi
