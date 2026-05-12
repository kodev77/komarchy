"""Spawn chromium with the bm profile and wait for CDP."""

import json
import os
import shutil
import signal
import subprocess
import threading
import time

from . import cdp
from .paths import CHROMIUM_PID, CHROMIUM_PROFILE, CDP_PORT


# Re-entry guard. close_chromium gets called from atexit, action_quit,
# action_quit_to_browser, and run_tui's _term — and on omarchy 3.7 these
# can fire close together when a SIGHUP/SIGTERM cascade interrupts an
# in-flight call. The full CDP teardown takes ~1–3s of slow blocking I/O
# (httpx + SSL init); without this guard, signal-driven re-entry stacks
# the recursion until cdp.list_tabs raises RecursionError and bm-py
# spins at 100% CPU. Only the first call runs the teardown.
_close_lock = threading.Lock()
_close_done = False


def close_chromium() -> None:
    """Tear down chromium with an escalation ladder so a single stuck
    tab can't leave the browser running:
      1. CDP /json/close every page Target. Cookie-flush path —
         chromium runs its normal clean-exit when the last tab closes,
         persisting session cookies (e.g. portal.azure.com auth).
      2. Wait up to 1.5s for chromium to exit on its own.
      3. SIGTERM the main chromium process directly by PID. Catches
         the case where one page refused /json/close (beforeunload
         handler, CDP-blocked dialog) and chromium therefore never
         reached the last-window-closed path.
      4. Wait another 1.5s for SIGTERM to take effect.
      5. SIGKILL — when chromium is genuinely stuck. Cookies may not
         flush, but the browser MUST die.
    Falls back to pkill --user-data-dir matching when chromium.pid is
    missing (e.g. chromium was launched outside bm-py)."""
    global _close_done
    if _close_done:
        return
    if not _close_lock.acquire(blocking=False):
        return
    try:
        if _close_done:
            return
        _close_chromium_inner()
        _close_done = True
    finally:
        _close_lock.release()


def _close_chromium_inner() -> None:
    try:
        tabs = cdp.list_tabs()
        for t in tabs:
            try:
                cdp.close_tab(t.id)
            except Exception:
                pass
    except Exception:
        pass
    cpid = _read_chromium_pid()
    if _wait_for_exit(cpid, 1.5):
        _drop_chromium_pid()
        return
    _signal_chromium(cpid, signal.SIGTERM)
    if _wait_for_exit(cpid, 1.5):
        _drop_chromium_pid()
        return
    _signal_chromium(cpid, signal.SIGKILL)
    _drop_chromium_pid()


def _read_chromium_pid() -> "int | None":
    try:
        return int(CHROMIUM_PID.read_text().strip())
    except (FileNotFoundError, ValueError, OSError):
        return None


def _wait_for_exit(pid: "int | None", timeout: float) -> bool:
    """Return True iff chromium has exited by the deadline. Uses the
    PID's liveness directly when available (instant), otherwise polls
    CDP — slower because CDP can briefly stay reachable while chromium
    is mid-shutdown, but it's the only signal we have without a PID."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pid is not None:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            except PermissionError:
                pass  # exists but un-signalable; keep polling
        elif not cdp.is_up():
            return True
        time.sleep(0.1)
    return False


def _signal_chromium(pid: "int | None", sig: int) -> None:
    if pid is not None:
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        return
    if not shutil.which("pkill"):
        return
    flag = "-KILL" if sig == signal.SIGKILL else "-TERM"
    try:
        subprocess.run(
            ["pkill", flag, "-f", f"user-data-dir={CHROMIUM_PROFILE}"],
            capture_output=True,
            timeout=2,
        )
    except (subprocess.SubprocessError, OSError):
        pass


def _drop_chromium_pid() -> None:
    """Remove the chromium PID file. Called after the chromium process
    has exited (or we've issued a kill). Best-effort — silent when the
    file is already gone."""
    try:
        CHROMIUM_PID.unlink()
    except (FileNotFoundError, OSError):
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
    proc = subprocess.Popen(
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
    # Persist chromium's PID so `bm browser` (and actions.raise_chromium)
    # can dispatch hyprland focus by pid:NNN. This is the only reliable
    # way to target the bm-managed chromium specifically: chromium on
    # Wayland ignores --class=, hardcoding its app_id to "chromium",
    # so `class:` matching would non-deterministically focus any
    # chromium window the user has open. The PID is concrete.
    try:
        CHROMIUM_PID.parent.mkdir(parents=True, exist_ok=True)
        CHROMIUM_PID.write_text(str(proc.pid))
    except OSError:
        pass


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
