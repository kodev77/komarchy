"""Shared logic used by both the TUI and the CLI subcommands."""

from typing import Optional
import json
import shutil
import subprocess
import time

from . import cdp, launcher, store


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


def cycle_saved_tab(direction: int) -> bool:
    """Advance (+1) or retreat (-1) through the user's **saved tabs** and
    activate the matching chromium tab, keeping focus where the user
    currently is. Returns True if a tab was activated, False on silent
    no-op (chromium not running / fewer than two saved tabs).

    This follows `saved-tabs.json` rather than chromium's live tab strip —
    it's the "jump through my bookmarks without opening bm" workflow that
    pairs with the TUI's preview mode. If the next saved URL is already
    open in chromium, `open_or_switch` activates that tab; otherwise it
    opens a fresh tab there. Either way, `raise_window=False` keeps focus
    on the app the user was just in.

    Position tracking uses the URL (not an index) as the "cursor" so
    edits to saved-tabs.json — reorders, adds, removes — never invalidate
    the cycle: if the URL we landed on last is still present, we resume
    from there; if it was removed, we fall back to the edge of the list
    so the next step lands on the first/last saved tab.
    """
    # Silent no-op when CDP isn't reachable — chromium + bm are paired,
    # so "chromium not running" also means bm isn't, and there's nothing
    # meaningful to cycle. We deliberately don't call launcher.ensure_up()
    # here; auto-launching chromium for a tab-cycle keypress would be
    # surprising and slow.
    if not cdp.is_up():
        return False
    saved = store.load_saved()
    if len(saved) < 2:
        return False

    state = store.load_state()
    last_url = state.get("tab_cycle_url", "")

    idx: Optional[int] = None
    for i, t in enumerate(saved):
        if t.url == last_url:
            idx = i
            break

    if idx is None:
        # First press, or the last-cycled URL was removed/edited.
        # Seed *just before* the edge so the first step lands cleanly
        # on saved[0] for next (+1) or saved[-1] for prev (-1).
        new_idx = 0 if direction > 0 else len(saved) - 1
    else:
        new_idx = (idx + direction) % len(saved)

    target_url = saved[new_idx].url

    prev_addr = active_window_address()
    try:
        open_or_switch(target_url, raise_window=False)
    except Exception:
        return False
    state["tab_cycle_url"] = target_url
    store.save_state(state)

    # Focus-restore dance (same as the TUI's preview mode). Sync call
    # catches the common case; a short sleep + second call catches
    # chromium's async BringToFront that sometimes lands after our
    # hyprctl dispatch returns.
    if prev_addr:
        focus_window(prev_addr)
        time.sleep(0.08)
        focus_window(prev_addr)
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
