from pathlib import Path
import os

HOME = Path.home()

SAVED_TABS = HOME / ".config" / "omarchy" / "bm" / "saved-tabs.json"
STATE_FILE = HOME / ".config" / "bm" / "state.json"
# PID of the running bm TUI, written on mount and removed on shutdown.
# The external cycle keybind (Super+Alt+J/K via `bm next`/`bm prev`)
# reads this file to find the TUI process and send SIGUSR1/SIGUSR2 —
# the TUI then handles cursor motion + activation in-process, so the
# external cycle walks the same tree the user sees without the CLI
# having to reconstruct state.
PID_FILE = HOME / ".config" / "bm" / "bm.pid"
FAVICON_CACHE = HOME / ".cache" / "bm" / "favicons"
CHROMIUM_PROFILE = HOME / ".config" / "bm" / "profile"

CDP_HOST = os.environ.get("BM_CDP_HOST", "localhost")
CDP_PORT = int(os.environ.get("BM_CDP_PORT", "9222"))
CDP_BASE = f"http://{CDP_HOST}:{CDP_PORT}"


def ensure_dirs() -> None:
    SAVED_TABS.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    FAVICON_CACHE.mkdir(parents=True, exist_ok=True)
    CHROMIUM_PROFILE.mkdir(parents=True, exist_ok=True)
