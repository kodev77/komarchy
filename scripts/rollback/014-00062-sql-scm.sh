#!/usr/bin/env bash
# sqlserver: rollback custom sql server cli wrapper using pymssql/freetds for azure sql queries
set -euo pipefail

if [[ ! -f "$HOME/.local/bin/sqlcmd" ]]; then
  echo "sqlcmd not found, skipping"
  exit 0
fi

echo "removing sqlcmd..."
rm "$HOME/.local/bin/sqlcmd"
echo "sqlcmd removed"
