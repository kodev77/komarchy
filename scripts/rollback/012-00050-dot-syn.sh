#!/usr/bin/env bash
# dotnet: cleanup placeholder — actual cleanup runs in 00046 (last in rollback order)
set -euo pipefail

echo "  dotnet sync: will clean after rollback"
