#!/usr/bin/env bash
# dotnet: .net sdk and runtime for building and running c# applications and web apis
set -euo pipefail

echo "installing/updating dotnet packages..."
yay -Syu --needed --noconfirm dotnet-sdk dotnet-runtime aspnet-runtime aspnet-targeting-pack dotnet-sdk-9.0 dotnet-runtime-9.0 aspnet-runtime-9.0 aspnet-targeting-pack-9.0
echo "  dotnet packages: OK"
