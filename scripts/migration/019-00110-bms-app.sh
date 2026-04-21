#!/usr/bin/env bash
# bm-tool: install the bm Python package via uv tool
set -euo pipefail

PKG_SRC="$REPO_DIR/files/local/share/bm"

if [[ ! -f "$PKG_SRC/pyproject.toml" ]]; then
  echo "package source missing at $PKG_SRC" >&2
  exit 1
fi

installer=""
if command -v uv >/dev/null 2>&1; then
  installer="uv"
elif command -v pipx >/dev/null 2>&1; then
  installer="pipx"
else
  echo "neither uv nor pipx available — run 019-00109-bms-uvi.sh first" >&2
  exit 1
fi

if [[ "$installer" == "uv" ]]; then
  echo "installing bm via uv tool"
  uv tool install --force --from "$PKG_SRC" bm
else
  echo "installing bm via pipx"
  pipx install --force "$PKG_SRC"
fi

if ! command -v bm-py >/dev/null 2>&1; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      echo "warning: $HOME/.local/bin not on PATH; bm-py may not be discoverable"
      ;;
  esac
fi

echo "bm package installed"
