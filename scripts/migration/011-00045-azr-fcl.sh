#!/usr/bin/env bash
# azure: cli for creating, testing, and deploying azure functions locally and to the cloud
set -euo pipefail

yay -S --needed --noconfirm azure-functions-core-tools-bin
echo "  azure-functions-core-tools-bin: OK"
