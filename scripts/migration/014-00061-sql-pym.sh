#!/usr/bin/env bash
# sqlserver: python library for connecting to sql server databases via freetds
set -euo pipefail

yay -S --needed --noconfirm python-pip
python3 -m pip install --user --break-system-packages pymssql
echo "  pymssql: OK"
