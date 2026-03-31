#!/usr/bin/env bash
# mysql: mariadb client for mysql-compatible database connections
set -euo pipefail

if ! pacman -Qi mariadb-clients &>/dev/null; then
  sudo pacman -S --noconfirm mariadb-clients
fi
echo "  mariadb-clients: OK"
