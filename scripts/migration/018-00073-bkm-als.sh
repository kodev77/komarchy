#!/usr/bin/env bash
# updates: bookmark manager alias and app-group files
set -euo pipefail

BASHRC="$HOME/.bashrc"
APP_GROUPS_DIR="$HOME/.config/omarchy/app-groups"
FILES_DIR="$REPO_DIR/files/config/omarchy/app-groups"

# copy bookmark files
mkdir -p "$APP_GROUPS_DIR"
for f in "$FILES_DIR"/*.md; do
  [ -f "$f" ] || continue
  cp "$f" "$APP_GROUPS_DIR/"
  echo "  $(basename "$f"): OK"
done

# add bm function
if grep -q "^bm()" "$BASHRC"; then
  echo "bm function already present, skipping"
  exit 0
fi

if grep -q '# --- BEGIN ko omarchy-setup bash-alias ---' "$BASHRC"; then
  sed -i "/alias ll='lsa'/a \\
bm() {\\
  local dir=~/.config/omarchy/app-groups\\
  case \"\${1:-}\" in\\
    ko)  nvim \"\$dir/ko.md\" ;;\\
    rpc) nvim \"\$dir/rpc.md\" ;;\\
    *)   nvim -O \"\$dir/ko.md\" \"\$dir/rpc.md\" ;;\\
  esac\\
}" "$BASHRC"
  echo "  bm function: added"
else
  echo "bash-alias block not found, skipping"
  exit 0
fi

echo ""
echo "open a new terminal to use: bm, bm ko, bm rpc"
