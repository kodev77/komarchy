#!/usr/bin/env bash
# dotnet: rollback azure artifacts credential provider for private nuget feeds
set -euo pipefail

CRED_DIR="$HOME/.nuget/plugins/netcore/CredentialProvider.Microsoft"

if [[ ! -d "$CRED_DIR" ]]; then
  echo "credential provider not found, skipping"
  exit 0
fi

echo "removing azure artifacts credential provider..."
rm -rf "$CRED_DIR"
echo "credential provider removed"
