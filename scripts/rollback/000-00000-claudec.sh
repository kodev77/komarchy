#!/usr/bin/env bash
# hello: uninstall claude code cli
set -euo pipefail

if command -v claude &>/dev/null; then
  echo "uninstalling claude code..."
  rm -f "$HOME/.local/bin/claude"
  rm -rf "$HOME/.local/share/claude"
  echo "claude code removed"
else
  echo "claude code not installed, skipping"
fi
