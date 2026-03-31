#!/usr/bin/env bash
# hello: install claude code cli
set -euo pipefail

if command -v claude &>/dev/null; then
  echo "claude code already installed ($(claude --version 2>/dev/null || echo 'unknown'))"
else
  echo "installing claude code..."
  curl -fsSL https://claude.ai/install.sh | bash
  echo "claude code installed"
fi
