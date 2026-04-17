#!/usr/bin/env bash
# terminal: rollback starship palette-name colors (restore bold cyan directory + hardcoded #f5a623 branch)
set -euo pipefail

STARSHIP="$HOME/.config/starship.toml"

if [[ ! -f "$STARSHIP" ]]; then
  echo "starship.toml not found, skipping"
  exit 0
fi

echo "reverting starship directory + git_branch to prior hardcoded colors..."

sed -i \
  -e 's|^style = "bold blue"$|style = "bold cyan"|' \
  -e 's|^repo_root_style = "bold blue"$|repo_root_style = "bold cyan"|' \
  -e 's|^style = "bold yellow"$|style = "bold #f5a623"|' \
  "$STARSHIP"

echo "  starship.toml: reverted"
