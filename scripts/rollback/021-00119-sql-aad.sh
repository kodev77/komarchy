#!/usr/bin/env bash
# updates: rollback go-sqlcmd swap, restore pymssql wrapper from repo
set -euo pipefail

DEST="$HOME/.local/bin/sqlcmd"
SRC="$REPO_DIR/files/local/bin/sqlcmd"

# idempotency: skip if pymssql wrapper already in place
if [[ -f "$DEST" ]] && head -2 "$DEST" 2>/dev/null | grep -q "pymssql"; then
  echo "pymssql sqlcmd wrapper already in place at $DEST"
  exit 0
fi

if [[ ! -f "$SRC" ]]; then
  echo "wrapper source not found at $SRC, cannot rollback"
  exit 1
fi

echo "restoring pymssql wrapper from $SRC..."
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "  sqlcmd: restored"
