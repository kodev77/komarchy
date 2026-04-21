from dataclasses import dataclass
from pathlib import Path
from typing import Optional
import time

from rich.style import Style
from rich.text import Text

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.reactive import reactive
from textual.screen import ModalScreen
from textual.widgets import Input, Tree
from textual.widgets.tree import TreeNode

from . import actions, cdp, favicon, launcher, store, theme as bm_theme

REFRESH_SECONDS = 3.0


@dataclass
class Row:
    """Selectable row in the tree — either a live CDP tab or a saved tab."""
    kind: str  # "live" or "saved"
    title: str
    url: str
    group: str = ""
    tab_id: str = ""


class _SearchMarker:
    """Sentinel data on the search-leaf so actions know to skip it."""


def _glyph(url: str) -> str:
    # Phase 1: render-path stays pure — no network calls. Kitty-graphics
    # rendering (which needs a cached PNG) lands in phase 2 with a background
    # fetch worker — see docs/bm-tool-PLAN.md.
    return favicon.FALLBACK_GLYPH


# Hyprland focus helpers now live in actions.py so both the TUI preview
# loop and the bm-next/bm-prev CLI subcommands share one implementation.
_active_window_address = actions.active_window_address
_focus_window = actions.focus_window


class BmApp(App):
    TITLE = "bm"
    CSS_PATH = "tui.tcss"
    ENABLE_COMMAND_PALETTE = False

    BINDINGS = [
        Binding("j,down", "cursor_down", "down", show=False),
        Binding("k,up", "cursor_up", "up", show=False),
        # Shift+hjkl mirror the lowercase motion keys (lazygit muscle memory).
        # The in-search case is handled by on_key directly, ahead of the
        # printable-char capture, so these bindings only need to cover the
        # normal-mode path.
        Binding("J", "cursor_down", "down", show=False),
        Binding("K", "cursor_up", "up", show=False),
        Binding("H", "collapse", "collapse", show=False),
        Binding("L", "expand", "expand", show=False),
        Binding("g,home", "jump_top", "top", show=False),
        Binding("G,end", "jump_bottom", "bottom", show=False),
        Binding("ctrl+d,pagedown", "half_page_down", "½↓", show=False),
        Binding("ctrl+u,pageup", "half_page_up", "½↑", show=False),
        Binding("h,left", "collapse", "collapse", show=False),
        Binding("l,right", "expand", "expand", show=False),
        # NOTE: Enter is intentionally NOT bound here — Textual's Tree widget
        # has its own `enter → select_cursor` binding that wins because the
        # tree is focused. We intercept the resulting Tree.NodeSelected
        # message in on_tree_node_selected instead.
        Binding("o", "open_saved", "open"),
        Binding("s", "save_selected", "save"),
        Binding("d", "delete_saved", "delete"),
        Binding("r", "rename_saved", "rename"),
        Binding("slash", "focus_search", "/"),
        Binding("p", "peek", "peek", show=False),
        Binding("P", "toggle_preview", "preview", show=False),
        Binding("question_mark", "show_help", "help", show=False),
        Binding("escape", "quit_to_browser", "browser"),
        Binding("q", "quit_to_browser", "quit"),
    ]

    filter_text: reactive[str] = reactive("")

    def __init__(self) -> None:
        super().__init__()
        self._live: list[cdp.Tab] = []
        self._saved: list[store.SavedTab] = []
        self._live_node: Optional[TreeNode] = None
        self._saved_nodes: dict[str, TreeNode] = {}
        # Stable first-seen order of chromium tab ids. Chromium's
        # /json/list returns tabs in MRU order on most builds, which means
        # every `cdp.activate` reshuffles the list — ugly if the user is
        # watching "Open Tabs" while cycling. We track insertion order
        # ourselves: keep ids that still exist, append new ones, drop
        # closed ones. Rendered by _stable_sort_live.
        self._live_order: list[str] = []
        # Raw omarchy colors, read once at startup. We read the dict directly
        # rather than going through self.current_theme because Textual's Theme
        # object sometimes normalizes or shades the hex we pass in, which
        # silently drops per-theme colors.
        self._omarchy_colors: dict = bm_theme.load_colors()

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Tree("bm", id="tree")
            yield Tree("search", id="search-tree")

    def on_mount(self) -> None:
        omarchy = bm_theme.load_theme()
        if omarchy is not None:
            self.register_theme(omarchy)
            self.theme = omarchy.name
        self.query_one("#tree", Tree).show_root = False
        search_tree = self.query_one("#search-tree", Tree)
        search_tree.show_root = False
        search_tree.can_focus = False
        search_tree.display = False
        self._load_all()
        self.set_interval(REFRESH_SECONDS, self._refresh_live)
        self.set_interval(0.5, self._blink_cursor)
        self.query_one("#tree", Tree).focus()

    def _blink_cursor(self) -> None:
        # Expire status messages whose timeout has elapsed.
        if self._status_message and time.monotonic() >= self._status_clear_at:
            self._status_message = ""
            self._update_search_tree()
        if self._in_search_mode:
            self._cursor_on = not self._cursor_on
            self._update_search_tree()
        # Cheap piggyback: follow external tab_cycle_url changes written by
        # the global Super+Alt+J/K keybinds, so the TUI cursor snaps to
        # whichever saved tab the keybind just activated in chromium.
        self._sync_cycle_cursor()

    def _sync_cycle_cursor(self) -> None:
        """Snap the tree cursor to the saved leaf whose URL matches
        state.json's `tab_cycle_url`, but only when that URL has *changed*
        since we last observed it. Local j/k navigation doesn't touch
        state.json, so the user's in-TUI cursor movement is never
        overridden — only external cycle-next/prev presses move the
        cursor. The actual `move_cursor` call is deferred via
        `call_after_refresh` so the tree is guaranteed to have been laid
        out (leaf `.line` set); calling it on a freshly-added leaf whose
        `.line` is still -1 silently snaps the cursor to 0 and leaves the
        TUI permanently out of sync with chromium until the user cycles
        to a different URL. We use `move_cursor` (not `select_node`)
        because `select_node` posts a `Tree.NodeSelected` message, which
        our on_tree_node_selected handler interprets as an Enter press
        and would spuriously activate tabs on every external sync."""
        if self._in_help_mode or self._in_search_mode:
            return
        try:
            state = store.load_state()
        except Exception:
            return
        url = state.get("tab_cycle_url", "")
        if not url or url == self._last_synced_cycle_url:
            return
        self._last_synced_cycle_url = url
        self.call_after_refresh(self._select_saved_url, url)

    def _select_saved_url(self, url: str) -> None:
        for gnode in self._saved_nodes.values():
            for leaf in gnode.children:
                row = leaf.data
                if isinstance(row, Row) and row.kind == "saved" and row.url == url:
                    if not gnode.is_expanded:
                        gnode.expand()
                    self.query_one("#tree", Tree).move_cursor(leaf)
                    return

    def _faded_fg(self, opacity: float = 0.65) -> str:
        # Blend theme foreground toward background to produce a dimmer hex.
        # `opacity` is the foreground weight: 1.0 = pure fg, 0.0 = pure bg.
        # Callers pass 0.65 for status messages (readable-but-dim) and 0.35
        # for the [preview] tag (noticeably dimmer — quiet edge marker).
        # Rich's [dim] only lands around 50% on most terminals and ignores
        # the theme, which is why we resolve a concrete per-theme hex here.
        from textual.color import Color
        theme = self.current_theme
        fg = Color.parse(theme.foreground or "#cccccc")
        bg = Color.parse(theme.background or "#000000")
        return fg.blend(bg, 1 - opacity).hex

    def _set_status(self, msg: str) -> None:
        """Show `msg` on the bottom status line for STATUS_DURATION seconds.
        Supersedes a prior message; search-mode display takes priority."""
        self._status_message = msg
        self._status_clear_at = time.monotonic() + self.STATUS_DURATION
        self._update_search_tree()

    def _update_search_tree(self) -> None:
        search_tree = self.query_one("#search-tree", Tree)
        # Priority for the primary (left-aligned) slot: active search >
        # ephemeral status > committed filter > empty. The [preview] tag
        # is a right-aligned suffix that rides alongside whichever primary
        # is showing, except during active typing where it's suppressed so
        # the prompt stays clean.
        # Two opacity tiers:
        #   - status / primary content → 0.65 (readable but clearly non-focal)
        #   - [preview] indicator       → 0.35 (noticeably dimmer — it's a
        #     persistent mode marker that should sit quietly at the edge,
        #     not compete with transient messages on the left)
        # Both are computed via _faded_fg which blends the theme's
        # foreground toward its background; Rich's [dim] only lands around
        # 50% on most terminals, so we resolve a concrete hex per theme.
        status_faded = self._faded_fg(0.65)
        preview_faded = self._faded_fg(0.35)
        primary: Optional[Text] = None
        if self._in_search_mode:
            primary = Text(f"/{self.filter_text}{'█' if self._cursor_on else ' '}")
        elif self._status_message:
            # Text() doesn't parse markup, so user content is literal —
            # no need to escape brackets in status messages.
            primary = Text(self._status_message, style=status_faded)
        elif self.filter_text:
            primary = Text(f"/{self.filter_text}")

        suffix: Optional[Text] = None
        if (
            self._in_preview_mode
            and not self._in_search_mode
            and not self._status_message
        ):
            # Literal "[preview]" in the dimmer preview-tier foreground.
            # Built via Text() (not markup) so the square brackets stay as
            # characters and don't need backslash escaping. Suppressed
            # while an ephemeral status message is showing so the message
            # gets the full row without being visually pushed around by
            # the right-edge tag; _blink_cursor re-renders when the status
            # times out, which brings [preview] back.
            suffix = Text("[preview]", style=preview_faded)

        if primary is None and suffix is None:
            search_tree.display = False
            return

        # Left-pad with one Braille Pattern Blank cell so the primary text
        # doesn't hug the window edge. U+2800 (not ASCII space) because
        # Tree strips leading whitespace from leaf labels — braille-blank
        # survives the normalizer. Same trick the help screen uses.
        label = Text("\u2800")
        if primary is not None:
            label.append(primary)

        if suffix is not None:
            # Right-align [preview] by inserting braille-blank padding
            # between primary and suffix until the suffix lands at the
            # right edge (with one cell of breathing room). size.width is
            # the tree's rendered width in cells. It's 0 when the widget
            # hasn't been laid out yet — which happens on the exact call
            # that flips display:False→True (this one, when toggling into
            # preview mode with nothing else showing). We use a minimum
            # gap for that first pass and schedule a re-render via
            # call_after_refresh; once layout has settled, size.width is
            # populated and [preview] snaps to the right edge. Without the
            # retry, the suffix visibly sat on the left until some
            # unrelated event (resize, status message) re-rendered.
            width = search_tree.size.width
            used = label.cell_len + suffix.cell_len
            if width == 0:
                gap = 2
                self.call_after_refresh(self._update_search_tree)
            else:
                gap = max(2, width - used - 1)
            label.append("\u2800" * gap)
            label.append(suffix)

        search_tree.display = True
        search_tree.clear()
        search_tree.root.add_leaf(label, data=_SearchMarker())

    def on_resize(self, event) -> None:
        # The [preview] suffix is right-aligned by baking literal padding
        # cells into the leaf label. When the terminal resizes, that frozen
        # padding no longer matches the new width — recompute.
        self._update_search_tree()

    _in_help_mode: bool = False
    _in_search_mode: bool = False
    _in_preview_mode: bool = False
    _cursor_on: bool = True
    _status_message: str = ""
    _status_clear_at: float = 0.0
    # Last `tab_cycle_url` we observed in state.json and snapped the cursor
    # to. Reset to "" on every _rebuild_tree so the post-rebuild cursor
    # picks the synced leaf back up instead of sitting at index 0.
    _last_synced_cycle_url: str = ""
    # Debounce handle for preview mode. Rapid j/k should coalesce into one
    # CDP activate; without this, mashing keys sends a burst of requests and
    # chromium visibly flickers through tabs.
    _preview_timer = None
    _preview_debounce: float = 0.1
    # Set True once we've *seen* chromium up. Used to distinguish
    # "chromium never started yet" (startup race) from "chromium was here
    # and is now gone" — the latter triggers bm to exit in lockstep.
    _chromium_seen_up: bool = False

    STATUS_DURATION = 3.0

    def _help_visible(self) -> bool:
        return self._in_help_mode

    def _set_help(self, visible: bool) -> None:
        self._in_help_mode = visible
        if visible:
            self._render_help_into_tree()
        else:
            self._rebuild_tree()

    def _render_help_into_tree(self) -> None:
        # Render help into the existing tree — Tree leaves are transparent,
        # unlike Static (which paints its whole area with $background and
        # shows opaque over ghostty's terminal opacity).
        #
        # Tree strips leading whitespace from labels, which broke plain
        # str.rjust() and even NBSP padding. Braille Pattern Blank (U+2800)
        # sidesteps that: it's a single-cell character that renders blank in
        # monospace fonts but is NOT classified as whitespace by Unicode /
        # str.isspace(), so Tree's normalizer leaves it in place. Net effect:
        # visually identical to leading spaces, key column right-aligned.
        tree = self.query_one("#tree", Tree)
        tree.clear()
        key_width = max(len(k) for k, _ in HELP_LINES)
        # Resolve the theme's secondary color (omarchy color6, the ANSI cyan
        # slot) at render time — Rich's Text.from_markup doesn't understand
        # Textual's $variable syntax, so passing "[$secondary]..." via
        # add_leaf crashes with a MarkupError. Passing a pre-built Rich Text
        # bypasses the markup parser entirely.
        # Build Rich Style objects from the raw omarchy colors. Textual 8.x's
        # markup system treats [#hex] as a variable reference, not a raw
        # color, which is why we can't use [#RRGGBB] markup here.
        #
        # Keys default to $accent (always legible against the theme bg).
        # Osaka Jade is the one exception — its accent is green, so we pull
        # color6 (the theme's bright cyan) for the keys there specifically.
        colors = self._omarchy_colors
        accent = colors.get("accent") or colors.get("color4") or "cyan"
        key_color = accent
        if bm_theme.load_name() == "osaka-jade":
            key_color = colors.get("color6") or accent
        key_style = Style(color=key_color)
        title_style = Style(color=accent, bold=True)
        left_margin = "\u2800"  # one braille-blank cell of breathing room

        title = Text()
        title.append(left_margin)
        title.append("Keybindings", style=title_style)
        tree.root.add_leaf(title)
        # Spacer row — a single braille-blank so the leaf survives Tree's
        # whitespace normalization (an empty string would render as nothing).
        tree.root.add_leaf(Text("\u2800"))

        for key, desc in HELP_LINES:
            pad = "\u2800" * (key_width - len(key))
            label = Text()
            label.append(left_margin)
            label.append(pad)
            label.append(key, style=key_style)
            label.append("   ")
            label.append(desc)
            tree.root.add_leaf(label)

        # Park the cursor on the blank spacer row so nothing visibly takes
        # the accent highlight on open, and the "Keybindings" title above
        # it is unreachable. action_cursor_up and action_jump_top clamp to
        # this same floor while help is visible.
        tree.cursor_line = _HELP_FIRST_ROW

    # --- data -----------------------------------------------------------

    def _load_all(self) -> None:
        self._saved = store.load_saved()
        try:
            live = cdp.list_tabs() if cdp.is_up() else []
        except Exception:
            live = []
        self._live = self._stable_sort_live(live)
        self._rebuild_tree()

    def _refresh_live(self) -> None:
        # The chromium-up/down check must run regardless of mode: when
        # chromium goes away we exit bm in lockstep, and a user sitting in
        # the help screen or a search prompt still expects that coupling
        # to fire. Only the *tree rebuild* is suppressed in help/search —
        # help mode is rendering the keybindings into the tree itself, and
        # search mode is showing a filtered view the user is actively
        # editing; neither should be clobbered by a 3-second live refresh.
        try:
            if cdp.is_up():
                self._chromium_seen_up = True
                if not self._in_help_mode and not self._in_search_mode:
                    self._live = self._stable_sort_live(cdp.list_tabs())
                    self._rebuild_tree()
            elif self._chromium_seen_up:
                # Chromium was running and has gone away — user closed it,
                # so exit bm in lockstep (the reverse coupling is handled
                # in action_quit_to_browser + atexit via launcher.close_chromium).
                self.exit()
        except Exception:
            pass

    def _stable_sort_live(self, tabs: list[cdp.Tab]) -> list[cdp.Tab]:
        """Render live tabs in a stable first-seen order instead of CDP's
        MRU order, so activating a tab doesn't reshuffle the Open Tabs
        list. Drops ids that no longer exist, appends newly-seen ids.
        Titles/URLs may still change (user navigating within a tab) —
        only *position* is stabilized, keyed by the immutable tab id."""
        current_ids = {t.id for t in tabs}
        self._live_order = [tid for tid in self._live_order if tid in current_ids]
        for t in tabs:
            if t.id not in self._live_order:
                self._live_order.append(t.id)
        by_id = {t.id: t for t in tabs}
        return [by_id[tid] for tid in self._live_order if tid in by_id]

    def _rebuild_tree(self) -> None:
        tree = self.query_one("#tree", Tree)
        # Capture the cursor's current row URL (and kind) so we can restore
        # the selection after tree.clear() wipes the cursor back to line 0.
        # Without this, the 3-second live-tab refresh — or any other
        # rebuild — would throw away local j/k navigation and snap the
        # cursor up to the "Open Tabs" header.
        prev_url = ""
        prev_kind = ""
        cur_node = tree.cursor_node
        if cur_node is not None and isinstance(cur_node.data, Row):
            prev_url = cur_node.data.url
            prev_kind = cur_node.data.kind

        tree.clear()
        f = self.filter_text.strip().lower()

        live_visible = [t for t in self._live if _match(t.title, t.url, f)]
        live_node = tree.root.add(
            f"▾ Open Tabs ({len(live_visible)})",
            expand=True,
        )
        self._live_node = live_node
        for t in live_visible:
            row = Row(kind="live", title=t.title, url=t.url, tab_id=t.id)
            live_node.add_leaf(_format_row(row), data=row)

        groups: dict[str, list[store.SavedTab]] = {}
        for t in self._saved:
            if not _match(t.title, t.url, f):
                continue
            groups.setdefault(t.group or "Unsorted", []).append(t)

        self._saved_nodes = {}
        for group_name in sorted(groups):
            items = groups[group_name]
            gnode = tree.root.add(
                f"▾ Saved: {group_name} ({len(items)})",
                expand=True,
            )
            self._saved_nodes[group_name] = gnode
            for s in items:
                row = Row(
                    kind="saved",
                    title=s.title,
                    url=s.url,
                    group=s.group,
                )
                gnode.add_leaf(_format_row(row), data=row)

        # Restore cursor onto the same URL the user was on, if it still
        # exists after the rebuild. _saved_nodes + _live_node give us a
        # fast path; if the URL no longer matches any leaf (tab closed,
        # saved tab removed, filter excludes it), we leave cursor at 0.
        # Deferred via call_after_refresh: right after tree.clear() and the
        # add_leaf calls above, Textual hasn't laid out the new nodes yet
        # — each leaf's `line` attribute is still -1, so moving the cursor
        # silently snaps it back to line 0. Running the restore on the next
        # refresh tick means layout has computed line numbers and the cursor
        # actually lands on the right row. We use `move_cursor` rather than
        # `select_node` so the restore doesn't post a Tree.NodeSelected
        # message that our on_tree_node_selected handler would treat as an
        # Enter press and activate the tab on every live-refresh tick.
        if prev_url:
            self.call_after_refresh(
                self._restore_cursor, tree, prev_url, prev_kind
            )

        self._update_search_tree()
        # NOTE: do NOT clear _last_synced_cycle_url here — doing so forces
        # _sync_cycle_cursor to re-apply state.json's tab_cycle_url on the
        # next blink and overrides the user's local navigation. The rebuild
        # already restores cursor to prev_url above; sync only fires when
        # tab_cycle_url *changes*, which is exactly what we want.

    def _restore_cursor(self, tree: Tree, url: str, kind: str) -> None:
        if kind == "live" and self._live_node is not None:
            for leaf in self._live_node.children:
                if isinstance(leaf.data, Row) and leaf.data.url == url:
                    tree.move_cursor(leaf)
                    return
        # Fall through for saved kind, or as fallback if live lookup missed.
        for gnode in self._saved_nodes.values():
            for leaf in gnode.children:
                if isinstance(leaf.data, Row) and leaf.data.url == url:
                    tree.move_cursor(leaf)
                    return

    # --- search ---------------------------------------------------------

    def on_key(self, event) -> None:
        if not self._in_search_mode:
            return
        k = event.key
        # Shift+hjkl navigates even while typing a filter. Handled here —
        # ahead of the printable-char capture below — because on_key runs
        # before any binding (priority or otherwise), so a Binding("H", ...)
        # would never fire during search. Lowercase hjkl still types (falls
        # through to the printable branch), matching search case-insensitively.
        shift_motion = {
            "J": self.action_cursor_down,
            "K": self.action_cursor_up,
            "H": self.action_collapse,
            "L": self.action_expand,
        }
        if k in shift_motion:
            shift_motion[k]()
            event.stop()
            return
        # escape is handled by action_quit_to_browser (via the Binding) so
        # the flow to clear search mode lives in one place.
        if k == "enter":
            self._in_search_mode = False
            self._rebuild_tree()
            event.stop()
            return
        if k == "backspace":
            self.filter_text = self.filter_text[:-1]
            self._rebuild_tree()
            event.stop()
            return
        ch = event.character or ""
        if len(ch) == 1 and ch.isprintable():
            self.filter_text += ch
            self._cursor_on = True
            self._rebuild_tree()
            event.stop()

    # --- actions --------------------------------------------------------

    def _selected_row(self) -> Optional[Row]:
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return None
        return node.data if isinstance(node.data, Row) else None

    # Motion actions are always safe — they just move the tree cursor. Search
    # mode still prevents plain hjkl from navigating because on_key consumes
    # printable chars ahead of bindings; shift+hjkl and arrows fall through
    # and drive these actions. Help mode now also allows motion so users can
    # scroll through the key list with j/k.

    def action_cursor_down(self) -> None:
        self.query_one("#tree", Tree).action_cursor_down()

    def action_cursor_up(self) -> None:
        tree = self.query_one("#tree", Tree)
        tree.action_cursor_up()
        self._clamp_help_cursor(tree)

    def action_jump_top(self) -> None:
        tree = self.query_one("#tree", Tree)
        tree.cursor_line = _HELP_FIRST_ROW if self._in_help_mode else 0

    def action_jump_bottom(self) -> None:
        tree = self.query_one("#tree", Tree)
        tree.cursor_line = max(0, tree.last_line)

    def action_half_page_down(self) -> None:
        tree = self.query_one("#tree", Tree)
        step = max(1, tree.size.height // 2)
        for _ in range(step):
            tree.action_cursor_down()

    def action_half_page_up(self) -> None:
        tree = self.query_one("#tree", Tree)
        step = max(1, tree.size.height // 2)
        for _ in range(step):
            tree.action_cursor_up()
        self._clamp_help_cursor(tree)

    def _clamp_help_cursor(self, tree: Tree) -> None:
        # In help mode rows 0 and 1 are the title and its spacer — they
        # shouldn't take cursor focus. After any upward motion, snap back
        # down if we've landed on them.
        if self._in_help_mode and tree.cursor_line < _HELP_FIRST_ROW:
            tree.cursor_line = _HELP_FIRST_ROW

    def action_collapse(self) -> None:
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        if node.allow_expand and node.is_expanded:
            node.collapse()
        elif node.parent is not None:
            # move_cursor (not select_node) — select_node posts
            # Tree.NodeSelected, which our handler interprets as an Enter
            # press AND which Tree's own auto-expand hook reacts to by
            # toggling the group. Both are wrong for "just move the cursor
            # up to the parent group".
            tree.move_cursor(node.parent)

    def action_expand(self) -> None:
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        if node.allow_expand and not node.is_expanded:
            node.expand()

    def action_focus_search(self) -> None:
        if self._in_help_mode:
            return
        self._in_search_mode = True
        self._cursor_on = True
        self._rebuild_tree()

    def action_activate(self) -> None:
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        if row.kind == "live":
            try:
                cdp.activate(row.tab_id)
                actions.raise_chromium()
            except Exception as exc:
                self._set_status(f"Failed to activate ({exc})")
        else:
            self._open_saved(row.url)

    def action_open_saved(self) -> None:
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._open_saved(row.url)

    def _open_saved(self, url: str) -> None:
        try:
            actions.open_or_switch(url)
        except Exception as exc:
            self._set_status(f"Failed to open ({exc})")
            return
        self._refresh_live()

    def action_save_selected(self) -> None:
        # Save the tab highlighted in the TUI — NOT chromium's active tab.
        # The CLI's `bm save` still uses actions.save_focused() for the
        # "save whatever chromium is showing right now" workflow (useful
        # from a hyprland keybind without opening bm). In the TUI, the
        # user has a cursor; respect it.
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            self._set_status("No tab selected")
            return
        if row.kind == "saved":
            self._set_status("Already saved")
            return
        try:
            store.add_saved(title=row.title or row.url, url=row.url)
        except Exception as exc:
            self._set_status(f"Failed to save ({exc})")
            return
        self._set_status("Saved Tab")
        self._load_all()

    def action_delete_saved(self) -> None:
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None or row.kind != "saved":
            return
        if store.remove_saved(row.url):
            self._set_status("Removed Tab")
            self._load_all()

    def action_rename_saved(self) -> None:
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None or row.kind != "saved":
            return
        self.push_screen(
            _RenameScreen(row.url, row.title),
            callback=lambda _: self._load_all(),
        )

    def action_quit_to_browser(self) -> None:
        if self._in_search_mode:
            self._in_search_mode = False
            self.filter_text = ""
            self._rebuild_tree()
            return
        if self._help_visible():
            self._set_help(False)
            return
        # bm and chromium are paired — closing one closes the other.
        launcher.close_chromium()
        self.exit()

    def action_show_help(self) -> None:
        if self._in_search_mode:
            return
        self._set_help(not self._help_visible())

    # --- peek + preview mode --------------------------------------------
    # `p` fires a one-shot peek — activate the selected tab in chromium
    # but keep focus in bm. `P` toggles a persistent preview mode where
    # every cursor move auto-peeks; the [preview] indicator in the status
    # line shows when it's on.
    #
    # Both paths go through _peek_row, which handles the focus-restore
    # dance around chromium's unsuppressible BringToFront.

    def action_peek(self) -> None:
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._peek_row(row)

    def action_toggle_preview(self) -> None:
        if self._in_help_mode or self._in_search_mode:
            return
        self._in_preview_mode = not self._in_preview_mode
        self._update_search_tree()
        if self._in_preview_mode:
            # Preview the row the cursor is already on — otherwise nothing
            # happens until the user moves.
            self._schedule_preview()
        elif self._preview_timer is not None:
            self._preview_timer.stop()
            self._preview_timer = None

    def on_tree_node_selected(self, event) -> None:
        # Textual's Tree widget owns the `enter` key — its built-in binding
        # posts this NodeSelected message. An App-level Binding("enter", ...)
        # would never fire because the focused Tree consumes the press first.
        # So we translate NodeSelected → action_activate here for leaves.
        # Branch nodes (group headers) have data=None; Tree's own auto-expand
        # hook handles their expand/collapse, and we fall through silently.
        if event.control is not self.query_one("#tree", Tree):
            return
        if self._in_help_mode or self._in_search_mode:
            return
        if isinstance(event.node.data, Row):
            self.action_activate()

    def on_tree_node_highlighted(self, event) -> None:
        # Fires on every cursor-line change within any Tree. We only care
        # about the main tree; the search-tree doesn't have highlightable
        # rows in a meaningful sense. Scheduling short-circuits if preview
        # mode is off or we're in help (rows are text, not tabs).
        if self._in_preview_mode and not self._in_help_mode:
            self._schedule_preview()

    def _schedule_preview(self) -> None:
        if self._preview_timer is not None:
            self._preview_timer.stop()
        self._preview_timer = self.set_timer(self._preview_debounce, self._do_preview)

    def _do_preview(self) -> None:
        self._preview_timer = None
        if not self._in_preview_mode or self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._peek_row(row)

    def _peek_row(self, row: Row) -> None:
        """Activate `row` in chromium (switch to its tab, or open it if it's
        a saved tab that's not open yet) while keeping keyboard focus in
        bm. Shared by the one-shot `p` peek and preview-mode's auto-peek.

        chromium's CDP /json/activate calls BringToFront internally, which
        raises the chromium window and steals focus on hyprland — there is
        no CDP flag to suppress that. Workaround: capture the currently-
        focused window (bm, since the user just pressed a key here) and
        reassert focus right after the activate. A second delayed refocus
        catches chromium's async window-activation event, which can land
        after the sync hyprctl call returns.

        Saved-tab peek uses actions.open_or_switch(raise_window=False) —
        it finds-or-creates a tab. Peeking the same URL repeatedly reuses
        one tab via cdp.find_by_url; peeking many different saved URLs
        will accumulate tabs (cost of the feature, not a bug)."""
        prev_addr = _active_window_address()
        try:
            if row.kind == "live":
                cdp.activate(row.tab_id)
            else:
                actions.open_or_switch(row.url, raise_window=False)
        except Exception as exc:
            self._set_status(f"Peek failed ({exc})")
            return
        if prev_addr:
            _focus_window(prev_addr)
            self.set_timer(0.08, lambda addr=prev_addr: _focus_window(addr))


def _match(title: str, url: str, needle: str) -> bool:
    if not needle:
        return True
    return needle in title.lower() or needle in url.lower()


def _format_row(row: Row) -> str:
    glyph = _glyph(row.url)
    return f"{glyph}  {row.title}"


_HELP_FIRST_ROW = 1  # title at 0, spacer at 1 (cursor floor), key rows at 2+


HELP_LINES = [
    ("j/k", "down / up"),
    ("h/l", "collapse / expand"),
    ("g/G", "top / bottom"),
    ("^D/^U", "half page"),
    ("Enter", "activate tab"),
    ("o", "open tab"),
    ("s", "save tab"),
    ("d", "delete saved"),
    ("r", "rename tab"),
    ("/", "search"),
    ("p", "preview tab"),
    ("P", "preview mode"),
    ("?", "help"),
    ("q/Esc", "close"),
]


class _RenameScreen(ModalScreen[str]):
    def __init__(self, url: str, title: str) -> None:
        super().__init__()
        self._url = url
        self._title = title

    def compose(self) -> ComposeResult:
        yield Input(value=self._title, id="rename")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        store.rename_saved(self._url, event.value)
        self.dismiss(event.value)


def run_tui() -> None:
    import atexit, signal, sys
    # Normal quit (Esc/q) → action_quit_to_browser handles it.
    # sys.exit / Textual's exit path → atexit.
    # Super+W / window close → ghostty dies, bm-py gets SIGHUP. atexit
    # does not fire for SIGHUP/SIGTERM, so install signal handlers too.
    atexit.register(launcher.close_chromium)

    def _term(_signum, _frame):
        launcher.close_chromium()
        sys.exit(0)

    for sig in (signal.SIGHUP, signal.SIGTERM):
        try:
            signal.signal(sig, _term)
        except (ValueError, OSError):
            pass
    BmApp().run()
