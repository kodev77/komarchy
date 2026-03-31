#!/usr/bin/env bash
# dotnet: neovim DAP launch config for C# test project
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/plugins"

echo "Writing dap-dotnet plugin spec..."

cat > "$NVIM_DIR/lua/plugins/dap-dotnet.lua" << 'DAPEOF'
return {
  {
    "mfussenegger/nvim-dap",
    opts = function()
      local dap = require("dap")

      -- Append project-specific launch configs for C#
      dap.configurations.cs = dap.configurations.cs or {}

      table.insert(dap.configurations.cs, {
        type = "netcoredbg",
        name = "JobTracker.Tests.DataverseIntegration",
        request = "launch",
        program = "${workspaceFolder}/JobTracker.Tests.DataverseIntegration/bin/Debug/net10.0/JobTracker.Tests.DataverseIntegration.dll",
        cwd = "${workspaceFolder}/JobTracker.Tests.DataverseIntegration",
        console = "internalConsole",
        stopAtEntry = true,
      })
    end,
  },
}
DAPEOF
echo "  plugins/dap-dotnet.lua: OK"
