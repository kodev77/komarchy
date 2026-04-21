"""Spawn chromium with the bm profile and wait for CDP."""

import json
import os
import shutil
import subprocess
import time

from . import cdp
from .paths import CHROMIUM_PROFILE, CDP_PORT


def close_chromium() -> None:
    """Close chromium by closing every tab via CDP so the browser runs
    its normal clean-exit path (the same one the user gets from File →
    Quit). That path flushes session cookies — SIGTERM does NOT, which
    is why auth for sites like portal.azure.com was being dropped when
    bm closed chromium with pkill alone. pkill runs as a fallback if
    CDP is unreachable or chromium doesn't exit promptly."""
    try:
        tabs = cdp.list_tabs()
        for t in tabs:
            try:
                cdp.close_tab(t.id)
            except Exception:
                pass
    except Exception:
        pass
    # Give chromium time to finish its clean shutdown.
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not cdp.is_up():
            return
        time.sleep(0.1)
    # CDP never went away — fall back to pkill.
    if not shutil.which("pkill"):
        return
    try:
        subprocess.run(
            ["pkill", "-TERM", "-f", f"user-data-dir={CHROMIUM_PROFILE}"],
            capture_output=True,
            timeout=2,
        )
    except (subprocess.SubprocessError, OSError):
        pass

BM_CLASS = "com.ko.bm"
DEFAULT_SIDEBAR_WIDTH = 300


def ensure_up(timeout: float = 15.0) -> bool:
    """Return True if CDP is reachable; spawn chromium first if not.

    Called before any CDP operation so the TUI self-heals when the user
    closes chromium but leaves bm running. When a respawn happens, also
    shrinks the bm window to the sidebar width so chromium tiles beside
    it with the intended layout (same behavior as the bash launcher's
    initial-startup path).
    """
    if cdp.is_up():
        return True
    if not shutil.which("chromium"):
        return False
    _spawn()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if cdp.is_up():
            clean_tabs()
            _shrink_bm_window()
            return True
        time.sleep(0.3)
    return False


def _spawn() -> None:
    CHROMIUM_PROFILE.mkdir(parents=True, exist_ok=True)
    _clear_crash_marker()
    subprocess.Popen(
        [
            "chromium",
            f"--remote-debugging-port={CDP_PORT}",
            f"--user-data-dir={CHROMIUM_PROFILE}",
            "--no-first-run",
            "--no-default-browser-check",
            # Session restore is required to keep in-memory/session
            # cookies (e.g. portal.azure.com's auth). We hide the
            # restored tab set immediately after launch via _clean_tabs().
            "--restore-last-session",
            "--disable-session-crashed-bubble",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _clear_crash_marker() -> None:
    """Mark the previous shutdown as clean (exit_type=Normal,
    exited_cleanly=true) and set restore_on_startup=1 so session cookies
    survive. The visible tab list is wiped post-launch by _clean_tabs().
    """
    prefs_path = CHROMIUM_PROFILE / "Default" / "Preferences"
    if not prefs_path.exists():
        return
    try:
        data = json.loads(prefs_path.read_text())
    except (json.JSONDecodeError, OSError):
        return
    profile = data.setdefault("profile", {})
    profile["exit_type"] = "Normal"
    profile["exited_cleanly"] = True
    session = data.setdefault("session", {})
    session["restore_on_startup"] = 1
    try:
        prefs_path.write_text(json.dumps(data))
    except OSError:
        pass


def clean_tabs() -> None:
    """Replace all currently-open tabs with a single fresh new-tab page.
    Called after chromium is spawned so the user sees a clean browser
    even though chromium technically restored the previous session (to
    preserve session cookies for authenticated sites)."""
    try:
        existing = cdp.list_tabs()
    except Exception:
        return
    if not existing:
        return
    try:
        # Open the blank tab FIRST — closing every tab would otherwise
        # leave chromium with zero tabs and trigger a browser shutdown.
        cdp.new_tab("about:blank")
    except Exception:
        return
    for t in existing:
        try:
            cdp.close_tab(t.id)
        except Exception:
            pass


def _shrink_bm_window() -> None:
    if not shutil.which("hyprctl"):
        return
    width = int(os.environ.get("BM_SIDEBAR_WIDTH", DEFAULT_SIDEBAR_WIDTH))
    try:
        out = subprocess.run(
            ["hyprctl", "clients", "-j"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        clients = json.loads(out.stdout or "[]")
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return
    addr = next(
        (c.get("address", "") for c in clients if c.get("class") == BM_CLASS),
        "",
    )
    if not addr:
        return
    for args in (
        ["hyprctl", "dispatch", "focuswindow", f"address:{addr}"],
        ["hyprctl", "dispatch", "resizeactive", "exact", str(width), "100%"],
    ):
        try:
            subprocess.run(args, capture_output=True, timeout=2)
        except (subprocess.SubprocessError, OSError):
            pass
