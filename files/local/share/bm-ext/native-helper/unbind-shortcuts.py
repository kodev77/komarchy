#!/usr/bin/env python3
"""Remove the bm extension's keyboard shortcut bindings from chromium.

Symmetric counterpart to bind-shortcuts.py. Used by the migration
rollback to leave the chromium profile in a clean state — no dangling
`linux:Alt+Shift+B` entry pointing at an extension that no longer
exists, no orphan `was_assigned: true` flags.

Same chromium-must-be-closed constraint as bind-shortcuts.py.

Usage:
  ./unbind-shortcuts.py <EXTENSION_ID>
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

PREFS = Path.home() / ".config" / "chromium" / "Default" / "Preferences"

# Includes legacy command names so a rollback on a machine migrated
# before the _execute_action switch still cleans up cleanly.
SHORTCUTS: set[str] = {"_execute_action", "save-current-tab", "toggle-sidepanel"}


def chromium_running() -> bool:
    return (
        subprocess.run(["pgrep", "-x", "chromium"], capture_output=True).returncode == 0
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: unbind-shortcuts.py <EXTENSION_ID>", file=sys.stderr)
        return 1

    ext_id = sys.argv[1]
    if not PREFS.exists():
        print(f"chromium profile not found at {PREFS} — nothing to unbind")
        return 0

    if chromium_running():
        print("chromium is running — close it before running this script", file=sys.stderr)
        return 1

    data = json.loads(PREFS.read_text())
    extensions = data.get("extensions", {})
    commands_map = extensions.get("commands", {})
    ext_settings = extensions.get("settings", {}).get(ext_id, {})
    ext_commands = ext_settings.get("commands", {})

    changed = False

    # Top-level commands map: remove every entry pointing at our extension.
    for key in [
        k
        for k, v in commands_map.items()
        if isinstance(v, dict)
        and v.get("extension") == ext_id
        and v.get("command_name") in SHORTCUTS
    ]:
        del commands_map[key]
        changed = True

    # Per-extension settings: clear was_assigned so a future bind step
    # re-applies cleanly rather than thinking it already ran.
    for cmd in SHORTCUTS:
        entry = ext_commands.get(cmd)
        if isinstance(entry, dict) and entry.pop("was_assigned", None) is not None:
            changed = True

    if not changed:
        print("no shortcut bindings found for this extension — nothing to do")
        return 0

    PREFS.write_text(json.dumps(data, separators=(",", ":")))
    print(f"unbound bm extension shortcuts from {PREFS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
