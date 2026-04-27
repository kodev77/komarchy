#!/usr/bin/env bash
# retro: rollback zork bash alias
set -euo pipefail

BASHRC="$HOME/.bashrc"
ZRK_BEGIN="# --- BEGIN ko komarchy zork alias ---"
ZRK_END="# --- END ko komarchy zork alias ---"

strip_block() {
  local file="$1" begin="$2" end="$3"
  [[ -f "$file" ]] || { echo "  $(basename "$file"): not found, skipping"; return 0; }
  if ! grep -qF "$begin" "$file"; then
    echo "  $(basename "$file"): zork alias block not present, skipping"
    return 0
  fi
  sed -i "/$begin/,/$end/d" "$file"
  echo "  $(basename "$file"): zork alias block removed"
}

strip_block "$BASHRC" "$ZRK_BEGIN" "$ZRK_END"

echo ""
echo "open a new terminal (or run: source ~/.bashrc) to drop the alias"
