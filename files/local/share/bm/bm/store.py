from dataclasses import dataclass, asdict
from datetime import date
import json
from typing import Optional

from .paths import SAVED_TABS, STATE_FILE, ensure_dirs


@dataclass
class SavedTab:
    title: str
    url: str
    group: str = "Unsorted"
    added: str = ""

    @classmethod
    def from_json(cls, data: dict) -> "SavedTab":
        return cls(
            title=data.get("title", ""),
            url=data.get("url", ""),
            group=data.get("group", "Unsorted") or "Unsorted",
            added=data.get("added", ""),
        )


def load_saved() -> list[SavedTab]:
    ensure_dirs()
    if not SAVED_TABS.exists():
        return []
    try:
        raw = json.loads(SAVED_TABS.read_text())
    except json.JSONDecodeError:
        return []
    return [SavedTab.from_json(t) for t in raw.get("tabs", [])]


def save_all(tabs: list[SavedTab]) -> None:
    ensure_dirs()
    payload = {"tabs": [asdict(t) for t in tabs]}
    SAVED_TABS.write_text(json.dumps(payload, indent=2) + "\n")


def add_saved(title: str, url: str, group: str = "Unsorted") -> SavedTab:
    tabs = load_saved()
    for t in tabs:
        if t.url == url:
            return t
    new = SavedTab(
        title=title,
        url=url,
        group=group,
        added=date.today().isoformat(),
    )
    tabs.append(new)
    save_all(tabs)
    return new


def remove_saved(url: str) -> bool:
    tabs = load_saved()
    kept = [t for t in tabs if t.url != url]
    if len(kept) == len(tabs):
        return False
    save_all(kept)
    return True


def rename_saved(url: str, new_title: str) -> bool:
    tabs = load_saved()
    for t in tabs:
        if t.url == url:
            t.title = new_title
            save_all(tabs)
            return True
    return False


def rename_group(old: str, new: str) -> bool:
    """Rewrite every member tab's group field from `old` to `new`.
    Returns True iff at least one tab moved. Caller is responsible for
    blocking renames of the special Essentials group — store.py treats
    group names as opaque strings."""
    tabs = load_saved()
    moved = False
    for t in tabs:
        if t.group == old:
            t.group = new
            moved = True
    if moved:
        save_all(tabs)
    return moved


def load_state() -> dict:
    ensure_dirs()
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except json.JSONDecodeError:
        return {}


def save_state(state: dict) -> None:
    ensure_dirs()
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")
