#!/usr/bin/env bash
# sqlserver: rollback python library for connecting to sql server databases via freetds
set -euo pipefail

echo "uninstalling pymssql..."
python3 -m pip uninstall -y pymssql 2>/dev/null || true
echo "pymssql removed"
