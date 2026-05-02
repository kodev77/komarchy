"""Shared logic used by both the TUI and the CLI subcommands."""

from typing import Optional
import json
import os
import shutil
import signal
import subprocess
import time

from . import cdp, launcher, store
from .paths import CHROMIUM_PID, PID_FILE


def raise_chromium() -> None:
    """Focus the bm-launched chromium window via PID lookup. Chromium
    on Wayland ignores --class=, hardcoding its app_id to "chromium",
    so class-based matching would non-deterministically focus any
    chromium window the user has running. PID is exact: launcher._spawn
    writes Popen().pid to CHROMIUM_PID at spawn, close_chromium unlinks
    it on shutdown.

    Stale PIDs (chromium died without bm cleanup) silently no-op and
    drop the file so the next press doesn't keep retrying."""
    pid = _read_chromium_pid()
    if not pid:
        return
    if not _pid_alive(pid):
        try:
            CHROMIUM_PID.unlink()
        except OSError:
            pass
        return
    try:
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"pid:{pid}"],
            check=False,
            capture_output=True,
        )
    except FileNotFoundError:
        pass


def _read_chromium_pid() -> int:
    try:
        return int(CHROMIUM_PID.read_text().strip())
    except (FileNotFoundError, ValueError, OSError):
        return 0


def _pid_alive(pid: int) -> bool:
    """True iff `pid` refers to a live process. Sends signal 0 — POSIX
    no-op that raises ProcessLookupError on a dead pid, PermissionError
    on a foreign-owned-but-alive pid (we treat that as alive)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


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
    return _signal_running_tui(sig)


def send_workspace_cycle_signal() -> bool:
    """Poke the running bm TUI with SIGRTMIN so it cycles to the next
    workspace in-process. Same dispatch pattern as send_cycle_signal,
    just a different signal so the TUI handler can route the action.
    Bound to Super+Alt+; via the `bm workspace next` CLI subcommand.
    Silent no-op when the TUI isn't running.
    """
    return _signal_running_tui(signal.SIGRTMIN)


def _signal_running_tui(sig: int) -> bool:
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


def copy_to_clipboard(text: str) -> bool:
    """Pipe `text` to wl-copy. Returns True on success, False if wl-copy
    is missing or exits non-zero. Wayland-only — bm runs under Hyprland,
    so X11 fallbacks (xclip/xsel) aren't worth the branch.

    stdout/stderr go to DEVNULL, not capture_output: wl-copy daemonizes
    a child to hold the selection until another app claims it, and the
    daemon inherits whatever stdout/stderr the parent passed. With
    pipe-backed capture_output, that daemon keeps the pipe FDs open
    indefinitely, communicate() never sees EOF, and subprocess.run
    raises TimeoutExpired after 2s — manifesting as a "Copy failed"
    status even though wl-copy worked. DEVNULL gives the daemon
    closed-equivalent FDs, so subprocess.run returns immediately
    once the parent forks the daemon and exits.
    """
    if not shutil.which("wl-copy"):
        return False
    try:
        subprocess.run(
            ["wl-copy"],
            input=text.encode("utf-8"),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
        return True
    except (subprocess.SubprocessError, OSError):
        return False


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


def save_focused(
    group: str = "Unsorted",
    workspace: Optional[str] = None,
) -> Optional[store.SavedTab]:
    """Save the currently-active Chromium tab. `workspace` is a
    workspace id (uuid hex) — when None, store.add_saved falls back to
    the first workspace in the array. Essentials are always global
    regardless."""
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
        workspace=workspace,
    )


def _focused_tab(tabs: list[cdp.Tab]) -> Optional[cdp.Tab]:
    # CDP /json/list returns tabs in MRU order on most builds; take the first page.
    for t in tabs:
        if t.kind == "page":
            return t
    return tabs[0] if tabs else None
