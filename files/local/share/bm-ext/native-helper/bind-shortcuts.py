#!/usr/bin/env python3
"""Ensure the bm extension's keyboard shortcuts are bound in chromium.

Chromium silently drops `suggested_key` entries from manifest.json when
it thinks there might be a conflict, so a fresh install can land with
some bm shortcuts unbound (the user has to manually re-bind them at
chrome://extensions/shortcuts). This script writes the bindings directly
into the chromium profile so the migration is fully self-serve.

Bindings live in two places inside ~/.config/chromium/Default/Preferences:

  1. extensions.commands["linux:<combo>"] = {command_name, extension, global}
  2. extensions.settings.<extId>.commands.<cmdName> = {suggested_key, was_assigned}

Both must exist for chromium to honour the binding.

CRITICAL: chromium must be CLOSED when this runs. Changes made while
chromium is running get clobbered on next shutdown, when chromium
rewrites Preferences from its in-memory copy.

Usage:
  ./bind-shortcuts.py <EXTENSION_ID>
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

PROFILE = Path.home() / ".config" / "chromium" / "Default"
PREFS = PROFILE / "Preferences"

# Keep in sync with the manifest's `commands` block.
#
# `_execute_action` is chromium's reserved command name for the toolbar
# action button. Binding a key to it makes chromium's *internal* handler
# fire (the same path as clicking the toolbar icon), which both opens
# the side panel and moves frame focus to it — something chrome.commands
# handlers can't do on their own.
SHORTCUTS: dict[str, str] = {
    "_execute_action": "Alt+Shift+B",
    "save-current-tab": "Alt+Shift+S",
}


def chromium_running() -> bool:
    # pgrep matches both `chromium` and `chromium --type=...` worker procs;
    # the main process is enough to indicate Preferences is in use.
    result = subprocess.run(
        ["pgrep", "-x", "chromium"], capture_output=True, text=True
    )
    return result.returncode == 0


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: bind-shortcuts.py <EXTENSION_ID>", file=sys.stderr)
        return 1

    ext_id = sys.argv[1]
    if not PREFS.exists():
        print(f"chromium profile not found at {PREFS}", file=sys.stderr)
        print("start chromium once to create it, then close and re-run", file=sys.stderr)
        return 1

    if chromium_running():
        print("chromium is running — close it before running this script", file=sys.stderr)
        print("(changes to Preferences are overwritten when chromium quits)", file=sys.stderr)
        return 1

    data = json.loads(PREFS.read_text())

    extensions = data.setdefault("extensions", {})
    commands_map = extensions.setdefault("commands", {})
    ext_settings = extensions.setdefault("settings", {}).setdefault(ext_id, {})
    ext_commands = ext_settings.setdefault("commands", {})

    changed = False
    for cmd_name, combo in SHORTCUTS.items():
        map_key = f"linux:{combo}"
        # Clear any other key currently pointing at this command so we
        # don't end up with stale duplicate bindings after a re-bind.
        stale_keys = [
            k for k, v in commands_map.items()
            if k != map_key
            and isinstance(v, dict)
            and v.get("command_name") == cmd_name
            and v.get("extension") == ext_id
        ]
        for k in stale_keys:
            del commands_map[k]
            changed = True

        existing = commands_map.get(map_key)
        if (
            not isinstance(existing, dict)
            or existing.get("command_name") != cmd_name
            or existing.get("extension") != ext_id
        ):
            commands_map[map_key] = {
                "command_name": cmd_name,
                "extension": ext_id,
                "global": False,
            }
            changed = True

        cmd_entry = ext_commands.setdefault(cmd_name, {})
        if (
            cmd_entry.get("suggested_key") != combo
            or not cmd_entry.get("was_assigned")
        ):
            cmd_entry["suggested_key"] = combo
            cmd_entry["was_assigned"] = True
            changed = True

    if not changed:
        print("shortcuts already bound — nothing to do")
        return 0

    # Chromium writes Preferences as minified JSON. Match that on the
    # way out so diffs against an untouched chromium write stay clean.
    PREFS.write_text(json.dumps(data, separators=(",", ":")))
    print(f"bound {len(SHORTCUTS)} shortcuts in {PREFS}")
    for cmd, combo in SHORTCUTS.items():
        print(f"  {combo:<16}  {cmd}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
