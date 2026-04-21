#!/usr/bin/env bash
# bm-tool: rollback bm package install
set -euo pipefail

removed=false

if command -v uv >/dev/null 2>&1; then
  if uv tool list 2>/dev/null | awk '{print $1}' | grep -qx 'bm'; then
    uv tool uninstall bm
    removed=true
  fi
  # Drop the cached build artifact so a subsequent re-migrate picks up any
  # source changes instead of hitting a stale wheel from the cache.
  uv cache clean bm >/dev/null 2>&1 || true
fi

if ! $removed && command -v pipx >/dev/null 2>&1; then
  if pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx 'bm'; then
    pipx uninstall bm
    removed=true
  fi
fi

if $removed; then
  echo "bm package removed (and uv cache cleaned)"
else
  echo "bm package not installed via uv/pipx, skipping"
fi
