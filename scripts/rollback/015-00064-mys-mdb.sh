#!/usr/bin/env bash
# mysql: rollback mariadb client for mysql-compatible database connections
set -euo pipefail

if ! pacman -Qi mariadb-clients &>/dev/null; then
  echo "mariadb-clients not installed, skipping"
  exit 0
fi

echo "removing mariadb-clients..."
sudo pacman -Rns --noconfirm mariadb-clients
echo "mariadb-clients removed"
