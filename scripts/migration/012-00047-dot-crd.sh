#!/usr/bin/env bash
# dotnet: azure artifacts credential provider for private nuget feeds
set -euo pipefail

if [[ -d "$HOME/.nuget/plugins/netcore/CredentialProvider.Microsoft" ]]; then
  echo "azure artifacts credential provider already installed, skipping"
  exit 0
fi

echo "installing azure artifacts credential provider..."
sh -c "$(curl -fsSL https://aka.ms/install-artifacts-credprovider.sh)"
echo "  credential provider: OK"
