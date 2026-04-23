"""Shared logic used by both the TUI and the CLI subcommands."""

from typing import Optional
import json
import os
import shutil
import signal
import subprocess
import time

from . import cdp, launcher, store
from .paths import PID_FILE


def raise_chromium() -> None:
    try:
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", "class:chromium"],
            check=False,
            capture_output=True,
        )
    except FileNotFoundError:
        pass


def active_window_address() -> str:
    """Current hyprland active-window address, or '' on failure.

    Used as the "remember where to send focus back to" capture before any
    CDP activate that shouldn't steal focus — chromium's BringToFront is
    not suppressible, so we reassert focus after the fact.
    """
    if not shutil.which("hyprctl"):
        return ""
    try:
        out = subprocess.run(
            ["hyprctl", "activewindow", "-j"],
            capture_output=True,
            text=True,
            timeout=1,
        )
        data = json.loads(out.stdout or "{}")
        return data.get("address", "") or ""
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return ""


def focus_window(address: str) -> None:
    if not address or not shutil.which("hyprctl"):
        return
    try:
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"address:{address}"],
            capture_output=True,
            timeout=1,
        )
    except (subprocess.SubprocessError, OSError):
        pass


def send_cycle_signal(direction: int) -> bool:
    """Poke the running bm TUI with SIGUSR1 (+1 = next) or SIGUSR2
    (-1 = prev) so it advances its cursor + activates the next row
    in-process. Returns True when the signal was delivered, False on
    silent no-op (bm TUI not running, PID file missing/stale, etc.).

    The TUI is the single source of truth for tree ordering and
    activation — this function only dispatches the intent; it does
    not read `saved-tabs.json` or query CDP directly. That keeps the
    cycle in lockstep with whatever the user sees in bm without the
    CLI having to reconstruct state.
    """
    sig = signal.SIGUSR1 if direction > 0 else signal.SIGUSR2
    try:
        pid = int(PID_FILE.read_text().strip())
    except (FileNotFoundError, ValueError, OSError):
        return False
    try:
        os.kill(pid, sig)
    except (ProcessLookupError, PermissionError, OSError):
        # Stale PID (TUI died without cleanup) or we lack perms to
        # signal. Best-effort cleanup of the stale file so the next
        # press doesn't keep retrying.
        try:
            PID_FILE.unlink()
        except OSError:
            pass
        return False
    return True


def open_or_switch(url: str, *, raise_window: bool = True) -> str:
    """Activate tab if URL already open; otherwise open it. Returns tab id.

    raise_window=False is used by the TUI's auto-preview mode, which wants
    chromium to switch the active tab without stealing window focus away
    from the bm terminal.
    """
    if not launcher.ensure_up():
        raise RuntimeError("chromium not reachable")
    existing = cdp.find_by_url(url)
    if existing is not None:
        cdp.activate(existing.id)
        if raise_window:
            raise_chromium()
        return existing.id
    tab = cdp.new_tab(url)
    if raise_window:
        raise_chromium()
    return tab.id


def save_focused(group: str = "Unsorted") -> Optional[store.SavedTab]:
    """Save the currently-active Chromium tab."""
    if not launcher.ensure_up():
        raise RuntimeError("chromium not reachable")
    tabs = cdp.list_tabs()
    focused = _focused_tab(tabs)
    if focused is None:
        return None
    return store.add_saved(
        title=focused.title or focused.url,
        url=focused.url,
        group=group,
    )


def _focused_tab(tabs: list[cdp.Tab]) -> Optional[cdp.Tab]:
    # CDP /json/list returns tabs in MRU order on most builds; take the first page.
    for t in tabs:
        if t.kind == "page":
            return t
    return tabs[0] if tabs else None
