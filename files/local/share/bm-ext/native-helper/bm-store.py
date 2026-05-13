#!/usr/bin/env python3
"""Native messaging host for the bm Chromium extension.

Speaks chromium's native messaging protocol (4-byte little-endian
length prefix + UTF-8 JSON) over stdin/stdout. Reads/writes the
git-tracked saved-tabs.json in komarchy.

Ops:
  {"op": "load"}              -> {"ok": true, "data": <Store>}
  {"op": "add_tab", "tab":    -> {"ok": true, "data": <Store>}
   {SavedTab fields}}
  {"op": "remove_tab",        -> {"ok": true, "data": <Store>}
   "id": "<uuid hex>"}

Errors:
  {"ok": false, "error": "<message>"}

This is the only writer of saved-tabs.json from the extension side.
The Python bm tool is the other writer; both produce byte-identical
v2 JSON so the file round-trips during the cutover.
"""

from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import uuid
from pathlib import Path

SCHEMA_VERSION = 2
DEFAULT_WORKSPACE_NAME = "Workspace"
ESSENTIALS_GROUP = "Essentials"

SAVED_TABS = (
    Path.home() / "repo" / "komarchy" / "files" / "config" / "omarchy" / "bm" / "saved-tabs.json"
)

# Omarchy publishes the active theme's canonical colors here. The file
# is the same one alacritty, waybar, mako, etc. read on every theme
# switch, so reading it gives us colors that already match the rest of
# the desktop.
OMARCHY_THEME_COLORS = Path.home() / ".config" / "omarchy" / "current" / "theme" / "colors.toml"


def read_message() -> dict:
    raw_len = sys.stdin.buffer.read(4)
    if len(raw_len) < 4:
        sys.exit(0)
    (length,) = struct.unpack("<I", raw_len)
    payload = sys.stdin.buffer.read(length)
    return json.loads(payload.decode("utf-8"))


def write_message(message: dict) -> None:
    payload = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(payload)))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def load_store() -> dict:
    """Read saved-tabs.json. On a missing file, seed a fresh v2 store
    with one default workspace and no tabs. We intentionally do NOT
    migrate v1 here — if the file is v1 (old python bm), the user
    should run the python bm once to upgrade it. Keeping migration
    in one place avoids two versions of the upgrade logic drifting.
    """
    if not SAVED_TABS.exists():
        seed = {
            "version": SCHEMA_VERSION,
            "workspaces": [{"id": uuid.uuid4().hex, "name": DEFAULT_WORKSPACE_NAME}],
            "tabs": [],
        }
        write_store(seed)
        return seed

    raw = json.loads(SAVED_TABS.read_text())
    if raw.get("version") != SCHEMA_VERSION:
        raise RuntimeError(
            f"saved-tabs.json is version {raw.get('version')!r}; "
            f"expected {SCHEMA_VERSION}. Run the python bm once to migrate."
        )
    # Pass through as-is; the extension trusts the schema.
    raw.setdefault("workspaces", [])
    raw.setdefault("tabs", [])
    return raw


def write_store(store: dict) -> None:
    """Atomic write: serialise to a sibling tempfile, then rename.
    Matches the formatting of the python bm (`json.dumps(..., indent=2)`
    + trailing newline) so diffs stay clean across both writers.
    """
    SAVED_TABS.parent.mkdir(parents=True, exist_ok=True)
    body = json.dumps(store, indent=2) + "\n"
    fd, tmp = tempfile.mkstemp(
        prefix=".saved-tabs.", suffix=".tmp", dir=str(SAVED_TABS.parent)
    )
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        os.replace(tmp, SAVED_TABS)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def add_tab(store: dict, tab: dict) -> dict:
    # Normalise: drop empty workspace field on Essentials so on-disk
    # form matches what the python bm produces.
    if tab.get("group") == ESSENTIALS_GROUP:
        tab.pop("workspace", None)
    if not tab.get("workspace"):
        tab.pop("workspace", None)
    store["tabs"].append(tab)
    return store


def remove_tab(store: dict, tab_id: str) -> dict:
    store["tabs"] = [t for t in store["tabs"] if t.get("id") != tab_id]
    return store


def load_theme() -> dict:
    """Parse omarchy's current theme colors.toml. Returns a flat dict
    of color name -> hex string. Missing file -> empty dict (extension
    falls back to its baked-in defaults)."""
    if not OMARCHY_THEME_COLORS.exists():
        return {}
    out: dict[str, str] = {}
    # colors.toml is a flat key/value file like `background = "#1e1e2e"`.
    # Rolling our own tiny parser instead of depending on tomllib so this
    # helper stays stdlib-only on any python3 version.
    for line in OMARCHY_THEME_COLORS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and value:
            out[key] = value
    return out


def dispatch(req: dict) -> dict:
    op = req.get("op")
    if op == "load":
        return {"ok": True, "data": load_store()}
    if op == "get_theme":
        return {"ok": True, "data": load_theme()}
    if op == "add_tab":
        tab = req.get("tab")
        if not isinstance(tab, dict) or not tab.get("id") or not tab.get("url"):
            return {"ok": False, "error": "add_tab requires a tab with id and url"}
        store = load_store()
        store = add_tab(store, tab)
        write_store(store)
        return {"ok": True, "data": store}
    if op == "remove_tab":
        tab_id = req.get("id")
        if not isinstance(tab_id, str) or not tab_id:
            return {"ok": False, "error": "remove_tab requires an id"}
        store = load_store()
        store = remove_tab(store, tab_id)
        write_store(store)
        return {"ok": True, "data": store}
    return {"ok": False, "error": f"unknown op: {op!r}"}


def main() -> None:
    try:
        req = read_message()
        res = dispatch(req)
    except Exception as e:
        res = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    write_message(res)


if __name__ == "__main__":
    main()
