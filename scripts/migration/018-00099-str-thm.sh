#!/usr/bin/env bash
# terminal: starship directory + git branch use palette names so colors flow with the active ghostty/omarchy theme
set -euo pipefail

STARSHIP="$HOME/.config/starship.toml"

if [[ ! -f "$STARSHIP" ]]; then
  echo "starship.toml not found, skipping"
  exit 0
fi

echo "switching starship directory + git_branch to palette-name colors..."

sed -i \
  -e 's|^style = "bold cyan"$|style = "bold blue"|' \
  -e 's|^repo_root_style = "bold cyan"$|repo_root_style = "bold blue"|' \
  -e 's|^style = "bold #f5a623"$|style = "bold yellow"|' \
  "$STARSHIP"

echo "  starship.toml: patched"
