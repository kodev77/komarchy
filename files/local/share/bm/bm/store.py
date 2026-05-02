from dataclasses import dataclass, asdict
from datetime import date
import json
import uuid

from .paths import SAVED_TABS, STATE_FILE, ensure_dirs


SCHEMA_VERSION = 2
ESSENTIALS_GROUP = "Essentials"
DEFAULT_WORKSPACE_NAME = "Workspace"


@dataclass
class Workspace:
    # uuid4 hex — stable across renames. Tabs reference this id (not the
    # name) via SavedTab.workspace, so renames are lossless.
    id: str
    name: str

    @classmethod
    def from_json(cls, data: dict) -> "Workspace":
        return cls(
            id=data.get("id") or uuid.uuid4().hex,
            name=data.get("name") or DEFAULT_WORKSPACE_NAME,
        )


@dataclass
class SavedTab:
    # uuid4 hex — stable across renames, URL edits, and group moves.
    # Session pairing, mutations (rename/move/update_url/remove), and
    # the in-memory Row all key on this id rather than URL, so duplicate
    # URLs anywhere in saved-tabs.json (across groups or within one)
    # don't collide.
    id: str
    title: str
    url: str
    group: str = "Unsorted"
    added: str = ""
    # Workspace id (uuid hex) the tab belongs to. Empty string means
    # "global" — used for Essentials tabs, which are visible in every
    # workspace's sidebar regardless. The render path treats
    # group == "Essentials" as global regardless of this field, so a
    # stray value can't take an Essential out of circulation.
    workspace: str = ""

    @classmethod
    def from_json(cls, data: dict) -> "SavedTab":
        return cls(
            # Backfill missing ids on load — saved-tabs.json predates the
            # id field, so existing entries get a fresh uuid here. The
            # backfilled value is persisted by load_saved on the way out
            # (see comment there) so subsequent reads — and other
            # processes like `bm save` / `bm rm` — see the same id.
            id=data.get("id") or uuid.uuid4().hex,
            title=data.get("title", ""),
            url=data.get("url", ""),
            group=data.get("group", "Unsorted") or "Unsorted",
            added=data.get("added", ""),
            workspace=data.get("workspace", "") or "",
        )

    def to_json(self) -> dict:
        # Strip the workspace field from the serialised form when empty
        # so Essentials tabs (which are global) and pre-v2 rows stay
        # tidy on disk. The loader treats missing/empty as global.
        out = asdict(self)
        if not out.get("workspace"):
            out.pop("workspace", None)
        return out


def _read_raw() -> dict:
    """Read the raw saved-tabs.json content as a dict. Returns an empty
    dict for a missing or malformed file so callers can treat it as
    'no data yet' without raising."""
    ensure_dirs()
    if not SAVED_TABS.exists():
        return {}
    try:
        return json.loads(SAVED_TABS.read_text())
    except json.JSONDecodeError:
        return {}


def _write_raw(workspaces: list[Workspace], tabs: list[SavedTab]) -> None:
    ensure_dirs()
    payload = {
        "version": SCHEMA_VERSION,
        "workspaces": [asdict(w) for w in workspaces],
        "tabs": [t.to_json() for t in tabs],
    }
    SAVED_TABS.write_text(json.dumps(payload, indent=2) + "\n")


def _migrate_v1_to_v2(raw: dict) -> tuple[list[Workspace], list[SavedTab], bool]:
    """Convert a pre-v2 saved-tabs.json shape into v2 in-memory form.

    Mints one workspace named DEFAULT_WORKSPACE_NAME, assigns every
    non-Essentials tab to it, leaves Essentials tabs without a
    workspace field. Returns (workspaces, tabs, mutated) where
    `mutated` is always True so the caller persists the upgrade back
    to disk.
    """
    seed = Workspace(id=uuid.uuid4().hex, name=DEFAULT_WORKSPACE_NAME)
    raw_tabs = raw.get("tabs", [])
    tabs: list[SavedTab] = []
    for raw_tab in raw_tabs:
        tab = SavedTab.from_json(raw_tab)
        if tab.group != ESSENTIALS_GROUP:
            tab.workspace = seed.id
        tabs.append(tab)
    return [seed], tabs, True


def load_all() -> tuple[list[Workspace], list[SavedTab]]:
    """Load workspaces + tabs from saved-tabs.json, auto-migrating
    older schema shapes on the fly. Persists any backfill (missing ids)
    and any v1→v2 upgrade back to disk so subsequent reads see the
    same state.
    """
    raw = _read_raw()
    version = raw.get("version", 1)

    if version < SCHEMA_VERSION or "workspaces" not in raw:
        # v1 (or older / unversioned). Run the upgrade path.
        if not raw:
            # No file at all: seed with one default workspace, no tabs.
            seed = Workspace(id=uuid.uuid4().hex, name=DEFAULT_WORKSPACE_NAME)
            _write_raw([seed], [])
            return [seed], []
        workspaces, tabs, mutated = _migrate_v1_to_v2(raw)
        if mutated:
            _write_raw(workspaces, tabs)
        return workspaces, tabs

    # v2+
    workspaces = [Workspace.from_json(w) for w in raw.get("workspaces", [])]
    raw_tabs = raw.get("tabs", [])
    needs_persist = any(not t.get("id") for t in raw_tabs)
    tabs = [SavedTab.from_json(t) for t in raw_tabs]
    # Belt-and-suspenders: if a non-Essentials tab somehow lacks a
    # workspace (manual edit, partial migration, etc.) and there's a
    # workspace available, assign it to the first one.
    if workspaces:
        fallback_ws = workspaces[0].id
        for tab in tabs:
            if tab.group != ESSENTIALS_GROUP and not tab.workspace:
                tab.workspace = fallback_ws
                needs_persist = True
    # Backfill the on-disk file if anything was minted on load so all
    # callers (the running TUI, `bm save`, `bm rm`) agree on ids.
    if needs_persist:
        _write_raw(workspaces, tabs)
    return workspaces, tabs


# --- Backwards-compatible saved-tab API (unchanged signatures) ---


def load_saved() -> list[SavedTab]:
    """Return just the saved tabs. Workspace metadata is loaded
    transparently but not exposed through this entry point — call
    sites that don't care about workspaces (CLI list, etc.) keep
    working unchanged."""
    _, tabs = load_all()
    return tabs


def load_workspaces() -> list[Workspace]:
    workspaces, _ = load_all()
    return workspaces


def save_all(tabs: list[SavedTab]) -> None:
    """Persist tabs while preserving the existing workspace list.
    Reads the current workspaces from disk so callers that only care
    about tabs don't need to thread workspaces through."""
    workspaces = load_workspaces()
    _write_raw(workspaces, tabs)


def _save_with_workspaces(
    workspaces: list[Workspace], tabs: list[SavedTab]
) -> None:
    _write_raw(workspaces, tabs)


def add_saved(
    title: str,
    url: str,
    group: str = "Unsorted",
    workspace: str | None = None,
) -> SavedTab:
    """Append a fresh SavedTab. No URL dedup — duplicate URLs across
    groups, within a group, or against an already-saved entry are all
    permitted. Each row gets its own uuid so subsequent rename / delete
    / move operations route to a specific entry rather than "every row
    matching a URL".

    If `workspace` is None and the tab isn't an Essential, the saver
    must supply one (callers in the TUI pass the current workspace id).
    Essentials always get an empty workspace field — they're global.
    """
    workspaces, tabs = load_all()
    if group == ESSENTIALS_GROUP:
        ws_id = ""
    elif workspace is None:
        # No workspace specified for a non-Essentials tab → fall back to
        # the first workspace in the array. Keeps callers that haven't
        # been updated for the workspace API working safely.
        ws_id = workspaces[0].id if workspaces else ""
    else:
        ws_id = workspace
    new = SavedTab(
        id=uuid.uuid4().hex,
        title=title,
        url=url,
        group=group,
        added=date.today().isoformat(),
        workspace=ws_id,
    )
    tabs.append(new)
    _save_with_workspaces(workspaces, tabs)
    return new


def remove_saved(saved_id: str) -> bool:
    workspaces, tabs = load_all()
    kept = [t for t in tabs if t.id != saved_id]
    if len(kept) == len(tabs):
        return False
    _save_with_workspaces(workspaces, kept)
    return True


def remove_saved_by_url(url: str) -> int:
    """Remove every saved tab matching `url` regardless of group or
    workspace. Used by the `bm rm <url>` CLI subcommand — without an
    id to disambiguate duplicates, removing all matches is the natural
    one-shot semantic. Returns the count removed (0 when no match)."""
    workspaces, tabs = load_all()
    kept = [t for t in tabs if t.url != url]
    removed = len(tabs) - len(kept)
    if removed:
        _save_with_workspaces(workspaces, kept)
    return removed


def remove_group(group: str, workspace_id: str) -> int:
    """Remove every saved tab whose (group, workspace) matches. Used by
    the `d` confirm-prompt action on a group header. Returns the count
    removed. Essentials are scoped globally (workspace_id ignored when
    group == "Essentials")."""
    workspaces, tabs = load_all()
    if group == ESSENTIALS_GROUP:
        kept = [t for t in tabs if t.group != group]
    else:
        kept = [
            t for t in tabs
            if not (t.group == group and t.workspace == workspace_id)
        ]
    removed = len(tabs) - len(kept)
    if removed:
        _save_with_workspaces(workspaces, kept)
    return removed


def move_saved(saved_id: str, new_group: str) -> bool:
    """Reassign the group of the saved tab whose id matches. Returns
    True iff the row was found and its group changed; False if the id
    isn't saved or it was already in `new_group`."""
    workspaces, tabs = load_all()
    for t in tabs:
        if t.id == saved_id:
            if t.group == new_group:
                return False
            t.group = new_group
            # Moving into / out of Essentials updates the workspace
            # field's role: Essentials tabs are global (empty
            # workspace); others stay scoped to their workspace.
            if new_group == ESSENTIALS_GROUP:
                t.workspace = ""
            elif not t.workspace and workspaces:
                t.workspace = workspaces[0].id
            _save_with_workspaces(workspaces, tabs)
            return True
    return False


def update_url(saved_id: str, new_url: str) -> bool:
    """Replace the URL of the saved tab whose id matches. Returns True
    iff the row was found and the URL actually changed; False if there's
    no match, the new URL is empty, or the URL is unchanged."""
    if not new_url:
        return False
    workspaces, tabs = load_all()
    for t in tabs:
        if t.id == saved_id:
            if t.url == new_url:
                return False
            t.url = new_url
            _save_with_workspaces(workspaces, tabs)
            return True
    return False


def rename_saved(saved_id: str, new_title: str) -> bool:
    workspaces, tabs = load_all()
    for t in tabs:
        if t.id == saved_id:
            t.title = new_title
            _save_with_workspaces(workspaces, tabs)
            return True
    return False


def rename_group(old: str, new: str, workspace_id: str | None = None) -> bool:
    """Rewrite member tabs' group field from `old` to `new`. When
    `workspace_id` is provided, only tabs in that workspace are
    rewritten — group names are unique per-workspace so this is the
    correct scoping. When None (legacy callers), every matching tab
    across every workspace is rewritten. Caller is responsible for
    blocking renames of the special Essentials group."""
    workspaces, tabs = load_all()
    moved = False
    for t in tabs:
        if t.group != old:
            continue
        if workspace_id is not None and t.workspace != workspace_id:
            continue
        t.group = new
        moved = True
    if moved:
        _save_with_workspaces(workspaces, tabs)
    return moved


# --- Workspace API ---


def add_workspace(name: str) -> Workspace:
    """Append a new workspace. Names are not required to be unique —
    identity is by id. Returns the created Workspace."""
    workspaces, tabs = load_all()
    new = Workspace(id=uuid.uuid4().hex, name=name or DEFAULT_WORKSPACE_NAME)
    workspaces.append(new)
    _save_with_workspaces(workspaces, tabs)
    return new


def remove_workspace(workspace_id: str) -> bool:
    """Destroy a workspace + every saved tab assigned to it. Refuses
    when this would leave zero workspaces. Returns True iff a
    workspace was removed."""
    workspaces, tabs = load_all()
    if len(workspaces) <= 1:
        return False
    if not any(w.id == workspace_id for w in workspaces):
        return False
    kept_workspaces = [w for w in workspaces if w.id != workspace_id]
    kept_tabs = [t for t in tabs if t.workspace != workspace_id]
    _save_with_workspaces(kept_workspaces, kept_tabs)
    return True


def rename_workspace(workspace_id: str, new_name: str) -> bool:
    """Rename a workspace by id. Tab references are unaffected (they
    point at id, not name). Returns True iff the workspace was found
    and the name actually changed."""
    if not new_name:
        return False
    workspaces, tabs = load_all()
    for w in workspaces:
        if w.id == workspace_id:
            if w.name == new_name:
                return False
            w.name = new_name
            _save_with_workspaces(workspaces, tabs)
            return True
    return False


def find_workspace_by_name(name: str) -> Workspace | None:
    """Lookup helper for the CLI, which addresses workspaces by name."""
    if not name:
        return None
    for w in load_workspaces():
        if w.name == name:
            return w
    return None


# --- State (local UI) ---


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


def get_current_workspace() -> str:
    """Return the workspace id last viewed by bm. Empty string if
    nothing has been written yet — callers fall back to workspaces[0]."""
    return load_state().get("currentWorkspace", "") or ""


def set_current_workspace(workspace_id: str) -> None:
    state = load_state()
    state["currentWorkspace"] = workspace_id
    save_state(state)


def get_open_tab_urls(workspace_id: str) -> list[str]:
    state = load_state()
    by_ws = state.get("openTabUrlsByWorkspace") or {}
    return list(by_ws.get(workspace_id) or [])


def set_open_tab_urls_map(by_workspace: dict[str, list[str]]) -> None:
    """Replace the entire openTabUrlsByWorkspace map. The TUI rewrites
    the whole thing each refresh tick from its in-memory _tab_workspace
    + cdp URLs, so a partial-update API isn't needed."""
    state = load_state()
    state["openTabUrlsByWorkspace"] = by_workspace
    save_state(state)


def get_group_order(workspace_id: str) -> list[str]:
    """User-chosen order of saved-group headers in `workspace_id`. New
    groups not yet in the list render in iteration order of `_saved`
    (creation order — `add_saved` appends), so the on-disk order is
    only mutated when the user actually reorders. Returns [] when
    nothing's been reordered yet for this workspace."""
    state = load_state()
    by_ws = state.get("groupOrderByWorkspace") or {}
    return list(by_ws.get(workspace_id) or [])


def set_group_order(workspace_id: str, order: list[str]) -> None:
    """Replace the group-order list for `workspace_id`. Drops the
    workspace key entirely when `order` is empty so state.json doesn't
    accumulate empty arrays."""
    state = load_state()
    by_ws = state.get("groupOrderByWorkspace") or {}
    if order:
        by_ws[workspace_id] = list(order)
    else:
        by_ws.pop(workspace_id, None)
    state["groupOrderByWorkspace"] = by_ws
    save_state(state)


def get_collapsed_groups(workspace_id: str) -> list[str]:
    """Group names the user has collapsed in `workspace_id`. Persisted
    so collapse state survives both workspace switches (rebuild_tree
    discards Textual's per-node is_expanded) and bm restarts. Returns
    [] when nothing's been collapsed yet for this workspace."""
    state = load_state()
    by_ws = state.get("collapsedGroupsByWorkspace") or {}
    return list(by_ws.get(workspace_id) or [])


def set_collapsed_groups(workspace_id: str, groups: list[str]) -> None:
    """Replace the collapsed-group list for `workspace_id`. Drops the
    workspace key entirely when `groups` is empty so state.json doesn't
    accumulate empty arrays for workspaces the user has fully
    expanded."""
    state = load_state()
    by_ws = state.get("collapsedGroupsByWorkspace") or {}
    if groups:
        by_ws[workspace_id] = sorted(set(groups))
    else:
        by_ws.pop(workspace_id, None)
    state["collapsedGroupsByWorkspace"] = by_ws
    save_state(state)


def get_filtered_groups(workspace_id: str) -> list[str]:
    """Group names the user has set to "filtered" in `workspace_id`.
    Filtered = the header is expanded but only saved children currently
    paired with an open chromium tab render; unopened saved tabs are
    hidden. Third state in the expanded/filtered/collapsed cycle."""
    state = load_state()
    by_ws = state.get("filteredGroupsByWorkspace") or {}
    return list(by_ws.get(workspace_id) or [])


def set_filtered_groups(workspace_id: str, groups: list[str]) -> None:
    """Replace the filtered-group list for `workspace_id`. Drops the
    workspace key entirely when `groups` is empty for the same tidiness
    reason as set_collapsed_groups."""
    state = load_state()
    by_ws = state.get("filteredGroupsByWorkspace") or {}
    if groups:
        by_ws[workspace_id] = sorted(set(groups))
    else:
        by_ws.pop(workspace_id, None)
    state["filteredGroupsByWorkspace"] = by_ws
    save_state(state)
