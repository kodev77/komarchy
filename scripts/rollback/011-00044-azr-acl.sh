#!/usr/bin/env bash
# azure: rollback command-line interface for managing azure resources, deployments, and subscriptions
set -euo pipefail

if ! pacman -Qi azure-cli &>/dev/null; then
  echo "azure-cli not installed, skipping"
  exit 0
fi

echo "removing azure-cli..."
sudo pacman -Rns --noconfirm azure-cli
echo "azure-cli removed"
