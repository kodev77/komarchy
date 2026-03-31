#!/usr/bin/env bash
# sqlserver: custom sql server cli wrapper using pymssql/freetds for azure sql queries
set -euo pipefail

mkdir -p "$HOME/.local/bin"

echo "Copying sqlcmd..."
cp "$REPO_DIR/files/local/bin/sqlcmd" "$HOME/.local/bin/sqlcmd"
chmod +x "$HOME/.local/bin/sqlcmd"

echo "  sqlcmd: OK"
