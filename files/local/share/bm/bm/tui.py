from dataclasses import dataclass
from pathlib import Path
from typing import Optional
import asyncio
import os
import signal
import time

from rich.style import Style
from rich.text import Text

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.color import Color
from textual.containers import Vertical
from textual.reactive import reactive
from textual.widgets import Tree
from textual.widgets.tree import TreeNode

from . import actions, cdp, favicon, launcher, store, theme as bm_theme
from .paths import PID_FILE, ensure_dirs

REFRESH_SECONDS = 0.3


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


class _WorkspaceMarker:
    """Sentinel data on the Workspace leaf — used by FolderTree.render_label
    to apply a dim overlay when the cursor lands on this row."""


class _EssentialsMarker:
    """Sentinel data on essentials leaves. Reserved for future actions
    (e.g., mapping Enter → open ChatGPT/Claude/Google). Hover styling is
    handled universally in FolderTree.render_label, so no per-row color
    needs to be stored here."""


class _GroupMarker:
    """Sentinel data on Saved group-header branches. Used by
    FolderTree.render_label to blend color13 on hover instead of
    repainting to the default foreground. Unsaved open tabs are
    rendered as bare root-level leaves (no group header), so this
    marker no longer applies to the "Open Tabs" section."""


class _SpacerMarker:
    """Sentinel data on blank separator rows (the braille-blank leaves
    between Workspace/Essentials/Saved groups/Open tabs). Motion actions
    use this to step over spacers so j/k/↑/↓ feel continuous — the
    cursor never parks on a visually-empty row."""


class FolderTree(Tree):
    """Tree using nerd-font folder glyphs for branch nodes.

    Overrides Textual's default ▶/▼ chevrons — two spaces after the glyph
    match the glyph+title spacing used by _format_row for leaf rows so
    parent and leaf columns align.
    """

    # Fraction of the foreground→background blend applied on hover.
    # 0.5 means the row's own color rendered at roughly 50% intensity
    # (blended halfway toward the theme background). Tune lower for a
    # more prominent hover, higher for a more subtle one.
    HOVER_DIM_FACTOR = 0.5

    # Esc-park state. When False, render_label stops treating any row
    # as the cursor, so the hover-dim overlay disappears. cursor_line
    # is preserved untouched — motion actions flip this back to True
    # and resume from where the user left off.
    cursor_active: reactive[bool] = reactive(True)

    def watch_cursor_active(self, old: bool, new: bool) -> None:
        # Tree keeps a per-line render cache keyed on (y, is_hover,
        # is_cursor, size, ...) — it doesn't know about cursor_active,
        # so a plain `refresh()` would hit the cache and serve the
        # pre-park strip for up to 3s (until _refresh_live's rebuild
        # invalidated the cache as a side effect). `_invalidate()` is
        # the method Tree calls internally for cursor_line/show_root/
        # etc. watchers; it clears the line cache and schedules a
        # full re-render.
        self._invalidate()

    def _hover_color(self, fg_hex):
        """Blend `fg_hex` toward the theme background by HOVER_DIM_FACTOR,
        returning the resulting hex. Falls back to the input on any
        parse failure so render stays robust if the theme is missing."""
        bg_hex = self.app._omarchy_colors.get("background")
        try:
            return Color.parse(fg_hex).blend(
                Color.parse(bg_hex), self.HOVER_DIM_FACTOR
            ).hex
        except Exception:
            return fg_hex

    def render_label(self, node, base_style, style):
        label = super().render_label(node, base_style, style)
        app = self.app
        colors = app._omarchy_colors
        # Inline rename: when a saved row is being renamed, replace its
        # label wholesale with `{glyph}  {buffer}{cursor}` in accent color.
        # Keeping the glyph prefix anchors the row visually so the user
        # sees "same row, just editable" instead of a separate widget.
        # Bypasses the rest of the styling flow (hover-dim, active-tab
        # highlight) deliberately — edit mode owns the row's appearance.
        rename_url = app._rename_url
        if (
            rename_url is not None
            and isinstance(node.data, Row)
            and node.data.kind == "saved"
            and node.data.url == rename_url
        ):
            accent = colors.get("accent") or "#cccccc"
            bg = colors.get("background") or "#000000"
            glyph = _glyph(node.data.url)
            buf = app._rename_buffer
            cur = max(0, min(app._rename_cursor, len(buf)))
            # Terminal-style cursor: the cursor sits *on* a character
            # (inverted fg/bg) rather than inserting a block between chars.
            # At end-of-buffer (cur == len(buf)) there's no real char, so
            # use a phantom space for the cursor cell.
            if cur < len(buf):
                head, cursor_char, tail = buf[:cur], buf[cur], buf[cur + 1:]
            else:
                head, cursor_char, tail = buf, " ", ""
            # Available cells for buffer content. Overhead subtracted:
            # ~2 indent + 1 glyph + 2 spaces + safety.
            avail = max(4, (self.size.width or 24) - 6)
            # Window the buffer around the cursor so both the cursor and
            # nearby text stay on-screen no matter where the cursor is.
            # Budget: avail total cells = len(head) + 1 (cursor) + len(tail).
            # When it overflows, prefer to give each side `half` cells;
            # hand the overflow room to the shorter side so we make the
            # most of the width, then replace clipped boundary chars with
            # `…` so the truncation is visually obvious.
            if len(head) + 1 + len(tail) > avail:
                half = max(1, (avail - 1) // 2)
                if len(head) <= half:
                    # head fits in its half — give extra room to tail
                    tail_room = avail - 1 - len(head)
                    if len(tail) > tail_room:
                        tail = (tail[:max(0, tail_room - 1)] + "…") if tail_room > 0 else ""
                elif len(tail) <= half:
                    # tail fits in its half — give extra room to head
                    head_room = avail - 1 - len(tail)
                    if len(head) > head_room:
                        head = "…" + head[-(max(0, head_room - 1)):] if head_room > 0 else ""
                else:
                    # Both sides overflow their halves — clip each to half
                    head_room = half
                    tail_room = avail - 1 - head_room
                    head = "…" + head[-(head_room - 1):] if head_room > 1 else "…"
                    tail = tail[:tail_room - 1] + "…" if tail_room > 1 else "…"
            label = Text()
            label.append(f"{glyph}  ", style=Style(color=accent))
            label.append(head, style=Style(color=accent))
            if app._cursor_on:
                # Invert: accent background, theme background as text —
                # gives the "block highlight on the char" look a terminal
                # cursor has, rather than a separate block character
                # pushing text around.
                label.append(cursor_char, style=Style(color=bg, bgcolor=accent))
            else:
                label.append(cursor_char, style=Style(color=accent))
            label.append(tail, style=Style(color=accent))
            return label
        # `cursor_active` drives the Esc-park state (defined above as a
        # reactive on this class). When False, no row is treated as the
        # cursor — the hover-dim disappears while cursor_line is kept
        # internally so motion resumes from where the user left off.
        is_cursor = self.cursor_node is node and self.cursor_active
        # "You are here" highlight: both live and saved rows carry the
        # chromium `tab_id` they represent (live: own id; saved: the
        # paired id resolved in _rebuild_tree). A row lights up iff
        # its tab_id matches `_active_tab_id`. This collapses the
        # earlier URL-based logic, which lit up every row sharing a
        # URL with the active tab — a problem whenever the user has
        # multiple chromium tabs on the same site. Empty tab_id on
        # either side never matches (bool() guard), so unpaired saved
        # rows and pre-activation state stay quiet.
        active_tab_id = getattr(app, "_active_tab_id", "")
        is_selected = (
            bool(active_tab_id)
            and isinstance(node.data, Row)
            and node.data.tab_id == active_tab_id
        )

        # Resolve the row's intended foreground + bold per marker type.
        # Re-applying after super() is load-bearing: Textual's Tree renders
        # with a computed `style` that includes the widget's default
        # color (typically `$text`), which overrides the per-label color
        # spans we baked at Text() creation. Always writing the color
        # here makes the styling robust to cursor movement AND to the
        # Esc-park state — a parked cursor used to wash the row out to
        # `$text` because the hover-dim branch (which re-colored) stopped
        # firing. Hover dim is now just a blended variant of the same
        # per-row color, so park mode shows the full, non-dimmed color.
        src = None
        bold = False
        if isinstance(node.data, _WorkspaceMarker):
            src = colors.get("accent") or colors.get("color4") or "#cccccc"
            bold = True
        elif isinstance(node.data, _EssentialsMarker):
            src = colors.get("color6") or colors.get("secondary") or "#cccccc"
        elif isinstance(node.data, _GroupMarker):
            src = colors.get("accent") or colors.get("color4") or "cyan"
            bold = True
        elif isinstance(node.data, Row):
            if is_selected:
                src = colors.get("color11") or "#E5C736"
            else:
                # Always set foreground explicitly for tab leaves. The
                # leaf label is a plain f-string with no intrinsic color,
                # so super()'s stylize applies Tree's computed color —
                # typically `$text` from Textual's defaults, which may
                # differ from the omarchy theme's `foreground` (e.g. a
                # "cream" base becoming pure white). Writing `foreground`
                # here keeps non-selected tabs on-theme, cursor-visible
                # or parked. Hover dim is a blend toward bg of this same
                # color.
                src = colors.get("foreground") or "#cccccc"
        if src is not None:
            # Exception: the active "you are here" tab keeps its full
            # color11 even when the cursor is parked on it — dimming
            # the one row that tells the user "this is the tab the
            # browser is showing" would undercut the whole point of
            # the highlight.
            dim = is_cursor and not is_selected
            color = self._hover_color(src) if dim else src
            label.stylize(Style(color=color, bold=bold))
        elif is_cursor:
            # Fallback for rows without a marker (e.g. help-screen
            # keybind rows, which have data=None and carry multi-span
            # intrinsic styling — colored key + plain description).
            # Applied only on the cursor row so non-cursor help rows
            # keep their per-span colors; on the cursor row we flatten
            # the whole label to the dim foreground so it reads as
            # "selected" without needing per-row colors.
            src = colors.get("foreground") or "#cccccc"
            label.stylize(Style(color=self._hover_color(src)))

        # Group-header branches: prepend the folder glyph. Matches the
        # label text's color treatment above so icon + header stay
        # visually unified under hover dim.
        if isinstance(node.data, _GroupMarker):
            glyph = self._FOLDER_OPEN if node.is_expanded else self._FOLDER_CLOSED
            icon_src = colors.get("accent") or colors.get("color4") or "cyan"
            icon_color = self._hover_color(icon_src) if is_cursor else icon_src
            icon_text = Text(f"{glyph}  ", style=Style(color=icon_color, bold=True))
            label = icon_text + label
        return label

    ICON_NODE = ""           # rendered inline in render_label
    ICON_NODE_EXPANDED = ""  # rendered inline in render_label
    _FOLDER_CLOSED = "\uf07b"  # nf-fa-folder
    _FOLDER_OPEN = "\uf07c"    # nf-fa-folder-open


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
            yield FolderTree("bm", id="tree")
            yield FolderTree("search", id="search-tree")

    def on_mount(self) -> None:
        omarchy = bm_theme.load_theme()
        if omarchy is not None:
            self.register_theme(omarchy)
            self.theme = omarchy.name
        main_tree = self.query_one("#tree", Tree)
        main_tree.show_root = False
        main_tree.guide_depth = 1  # minimum viable indent (default is 4)
        search_tree = self.query_one("#search-tree", Tree)
        search_tree.show_root = False
        search_tree.can_focus = False
        search_tree.display = False
        self._load_all()
        # Write our PID so the external cycle keybind can find us.
        # `bm next`/`bm prev` reads this file and sends SIGUSR1/SIGUSR2;
        # the handler below advances the cursor and activates in-
        # process, so the external cycle reuses the TUI's own motion +
        # Enter logic rather than reconstructing tree state in the CLI.
        try:
            ensure_dirs()
            PID_FILE.write_text(str(os.getpid()))
        except OSError:
            pass
        # Install SIGUSR1 (cycle next) and SIGUSR2 (cycle prev) via
        # asyncio's signal machinery so the callback runs on the event
        # loop thread — safe to touch Textual state from there.
        # `get_running_loop()` works because Textual's on_mount is
        # invoked inside the running loop. Platforms without UNIX
        # signals (unlikely for bm's target, but defensive) fall
        # through silently.
        try:
            loop = asyncio.get_running_loop()
            loop.add_signal_handler(
                signal.SIGUSR1, lambda: self._cycle_step(+1)
            )
            loop.add_signal_handler(
                signal.SIGUSR2, lambda: self._cycle_step(-1)
            )
        except (NotImplementedError, RuntimeError):
            pass
        self.set_interval(REFRESH_SECONDS, self._refresh_live)
        self.set_interval(0.5, self._blink_cursor)
        tree = self.query_one("#tree", FolderTree)
        tree.focus()
        # Park the cursor on first paint so the hover-dim doesn't land
        # on the Workspace row before the user has actually navigated.
        # Any motion action (j/k, external cycle, etc.) reactivates it
        # via _activate_cursor.
        tree.cursor_active = False

    def _blink_cursor(self) -> None:
        # Expire status messages whose timeout has elapsed.
        if self._status_message and time.monotonic() >= self._status_clear_at:
            self._status_message = ""
            self._update_search_tree()
        if self._in_search_mode:
            self._cursor_on = not self._cursor_on
            self._update_search_tree()
        elif self._rename_url is not None:
            # Inline rename has its own cursor glyph drawn by render_label;
            # toggle the shared flag and invalidate the tree so the block
            # character blinks in place on the row being edited.
            self._cursor_on = not self._cursor_on
            self.query_one("#tree", FolderTree)._invalidate()

    def _cycle_step(self, direction: int) -> None:
        """External cycle handler, invoked from SIGUSR1/SIGUSR2 (see
        on_mount). Advances the tree cursor by one step, skipping rows
        that shouldn't participate in the cycle (Workspace title,
        saved-group headers, braille-blank spacers), wrapping at the
        tree edges. Once the cursor lands on an actionable row,
        activates it via _peek_row — same path as TUI preview mode,
        which switches the chromium tab without raising the chromium
        window. Chromium still gets raised internally by CDP's
        BringToFront, but _peek_row's focus-restore dance snaps focus
        back to whichever window the user was in when they pressed
        the keybind.

        Essentials lack URLs by design, so landing on one leaves
        chromium on its current tab — cursor moves, no activation
        attempted. Help / search mode short-circuit: in help we don't
        want motion to rewrite the keybind list, and in search the
        filter owns j/k already."""
        if self._in_help_mode or self._in_search_mode:
            return
        tree = self.query_one("#tree", FolderTree)
        last_line = max(0, tree.last_line)
        if last_line <= 0:
            return
        # Bounded traversal — at most a full wrap — so we can't loop
        # forever if every row is somehow a skip marker.
        for _ in range(last_line + 2):
            prev_line = tree.cursor_line
            if direction > 0:
                tree.action_cursor_down()
            else:
                tree.action_cursor_up()
            if tree.cursor_line == prev_line:
                # At top/bottom edge — wrap to the other end and
                # continue searching for a cyclable row from there.
                tree.cursor_line = 0 if direction > 0 else last_line
            node = tree.cursor_node
            if node is None:
                continue
            if isinstance(
                node.data,
                (_SpacerMarker, _WorkspaceMarker, _GroupMarker),
            ):
                continue
            break
        # Keep cursor_active=True so the hover-dim shows on whichever
        # row the cycle landed on — gives the user a visible pointer
        # in the tree as they step through from another app. For rows
        # that get activated immediately below, color11 paints over
        # the dim (render_label suppresses dim when `is_selected` is
        # true); essentials aren't activated so the dim stays visible
        # to mark the cursor position.
        self._activate_cursor()
        row = self._selected_row()
        if row is not None:
            self._peek_row(row)

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
        # Mode markers in the right-aligned slot: `[rename]` takes priority
        # over `[preview]` since rename is a modal edit and preview is
        # passive. Both use the same dim preview-tier color so they feel
        # like the same tier of indicator. Both suppress during search
        # typing and ephemeral status messages (the message gets the full
        # row; `_blink_cursor` re-renders when the status times out, which
        # brings the marker back). `_in_preview_mode` is independent state,
        # so exiting rename mode restores `[preview]` automatically on the
        # next `_update_search_tree` call — no extra bookkeeping needed.
        if (
            self._rename_url is not None
            and not self._in_search_mode
            and not self._status_message
        ):
            suffix = Text("[rename]", style=preview_faded)
        elif (
            self._in_preview_mode
            and not self._in_search_mode
            and not self._status_message
        ):
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
        # Two width-frozen labels need recomputing on resize:
        #   - search tree's [preview] suffix — right-aligned by baked padding.
        #   - main tree's essentials row — space-evenly distributed by baked
        #     gap math ((W - N) / (N + 1) per gap).
        # Both bake the width into the leaf label at build time, so a resize
        # leaves them misaligned until we rebuild.
        self._update_search_tree()
        self._rebuild_tree()

    _in_help_mode: bool = False
    _in_search_mode: bool = False
    _in_preview_mode: bool = False
    # Inline rename state. `_rename_url` is the URL of the saved row
    # being edited (None outside rename mode); `_rename_buffer` is the
    # in-progress title; `_rename_cursor` is the 0..len(buffer) insertion
    # index for arrow-key motion, inserts, and backspace/delete.
    # `FolderTree.render_label` keys off `_rename_url` to draw an editable
    # field on that row in place of its title.
    _rename_url: Optional[str] = None
    _rename_buffer: str = ""
    _rename_cursor: int = 0
    # Suppression window for the NodeSelected message the Tree posts when
    # its own enter-binding fires in parallel with our on_key rename-commit.
    # Without this, committing a rename with Enter also activates the tab
    # (opens chromium to it). A monotonic-time deadline beats a
    # `call_after_refresh`-cleared flag because the Tree's refresh callback
    # runs *before* the queued NodeSelected is processed — the flag would
    # already be cleared by the time we'd want to consume it. Timestamps
    # don't rely on callback ordering.
    _suppress_activate_until: float = 0.0
    # URL of the row the user last activated (Enter/o/p/preview-cursor-move).
    # FolderTree.render_label paints the matching row with the theme's
    # `color5` so the "you are here" tab stays visually pinned even after
    # the cursor moves away. Empty string means no active selection.
    _active_url: str = ""
    # Chromium tab id that the URL above resolved to on activation.
    # Needed to disambiguate when multiple live tabs share a URL —
    # without it, opening saved Yahoo while two other Yahoo tabs are
    # open lights up all three rows. Saved rows still highlight on URL
    # alone (they have no chromium id); live rows require both URL and
    # tab_id to match. Empty string means no live row highlights (used
    # when the activation path didn't report an id, e.g. external
    # cycle) — the saved row's URL highlight is still enough to show
    # the user where the cycle landed.
    _active_tab_id: str = ""
    _cursor_on: bool = True
    _status_message: str = ""
    _status_clear_at: float = 0.0
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
        # Keys use color6 (the theme's secondary, typically cyan) to match
        # the essentials row in the main tree — gives the help screen's
        # command column the same visual treatment. Falls back to $accent
        # if the theme doesn't expose color6.
        colors = self._omarchy_colors
        accent = colors.get("accent") or colors.get("color4") or "cyan"
        key_color = colors.get("color6") or colors.get("secondary") or accent
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
        # to fire. Only the *tree rebuild* is suppressed in help/search/
        # rename — help renders keybindings into the tree itself, search
        # is showing a filtered view the user is actively editing, and
        # rename is mid-edit on a specific row; none should be clobbered
        # by the live refresh.
        try:
            if cdp.is_up():
                self._chromium_seen_up = True
                if (
                    not self._in_help_mode
                    and not self._in_search_mode
                    and self._rename_url is None
                ):
                    raw_tabs = cdp.list_tabs()
                    # chromium's /json/list returns pages in MRU order,
                    # so the first entry is the currently-focused tab.
                    # Use that to follow manual tab switches inside
                    # chromium (clicking a tab, Ctrl+Tab, etc.) — bm
                    # doesn't observe those events directly, so this
                    # sample is how the "you are here" highlight tracks
                    # the browser's actual focus, not just the last tab
                    # bm itself activated.
                    chromium_focused = raw_tabs[0] if raw_tabs else None
                    new_live = self._stable_sort_live(raw_tabs)
                    # Diff gate: tick fires every REFRESH_SECONDS but
                    # the tree only rebuilds when something visible
                    # actually changed — tab opened/closed, title/URL
                    # updated, or chromium focus moved. Most ticks are
                    # pure polling (two localhost HTTP calls, ~2-5ms
                    # total), which lets us poll more frequently than
                    # the old 3s cadence without paying for redundant
                    # repaints.
                    tabs_changed = self._tabs_differ(self._live, new_live)
                    active_changed = (
                        chromium_focused is not None
                        and chromium_focused.id != self._active_tab_id
                    )
                    self._live = new_live
                    if active_changed:
                        self._active_url = chromium_focused.url
                        self._active_tab_id = chromium_focused.id
                    if tabs_changed or active_changed:
                        self._rebuild_tree()
            elif self._chromium_seen_up:
                # Chromium was running and has gone away — user closed it,
                # so exit bm in lockstep (the reverse coupling is handled
                # in action_quit_to_browser + atexit via launcher.close_chromium).
                self.exit()
        except Exception:
            pass

    def _tabs_differ(
        self, old: list[cdp.Tab], new: list[cdp.Tab]
    ) -> bool:
        """True when the user-visible tab state has changed since the
        last refresh — used by _refresh_live to skip rebuilds on no-op
        ticks. Compares (id, url, title) tuples: id covers open/close,
        url + title cover in-tab navigation (both of which show in the
        rendered label). MRU-order-only shuffles don't count because
        self._live is passed through _stable_sort_live first."""
        if len(old) != len(new):
            return True
        return (
            {(t.id, t.url, t.title) for t in old}
            != {(t.id, t.url, t.title) for t in new}
        )

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
        # cursor back up to the Workspace row.
        prev_url = ""
        prev_kind = ""
        cur_node = tree.cursor_node
        if cur_node is not None and isinstance(cur_node.data, Row):
            prev_url = cur_node.data.url
            prev_kind = cur_node.data.kind

        tree.clear()

        # Workspace header — placeholder top-level row representing the
        # current workspace of saved tabs. No children yet; will anchor
        # workspace-level actions later. Added as a leaf so FolderTree's
        # folder chevron doesn't render on it — the briefcase glyph stands
        # alone. Sits above the filter so search doesn't hide it.
        # Match the help-screen "Keybindings" title styling: omarchy
        # accent color, bold. Same resolution path (accent → color4 → cyan).
        accent = (
            self._omarchy_colors.get("accent")
            or self._omarchy_colors.get("color4")
            or "cyan"
        )
        workspace_style = Style(color=accent, bold=True)
        # Match the Keybindings title layout: braille-blank left margin
        # (unstyled) + the label with title style. Tree strips empty
        # strings so the margin has to be a real-but-invisible char.
        workspace_label = Text()
        workspace_label.append("\u2800")
        workspace_label.append("Workspace", style=workspace_style)
        tree.root.add_leaf(workspace_label, data=_WorkspaceMarker())

        # Essentials — 3 top-level rows for the user's global links.
        # Hardcoded for now; styled with the theme's secondary color
        # (`color6`, typically cyan) so they visually distinguish from
        # the green `accent` used on Workspace/Saved headers.
        # Not bold — only the Workspace row uses bold as a title.
        # Added as leaves (no children) — branches would auto-render
        # the FolderTree folder glyph, which we don't want here.
        essentials_accent = (
            self._omarchy_colors.get("color6")
            or self._omarchy_colors.get("secondary")
            or "cyan"
        )
        essentials_style = Style(color=essentials_accent)
        # Section break above essentials, separating from Workspace.
        # _SpacerMarker tags it as skip-on-motion so j/k don't park here.
        tree.root.add_leaf(Text("\u2800"), data=_SpacerMarker())

        essentials_entries = [
            ("", "ChatGPT"),    # nf-fa-commenting
            ("", "Claude AI"),  # nf-fa-lightbulb
            ("", "Google"),     # nf-fa-google
        ]
        for glyph, name in essentials_entries:
            # No left margin here (unlike Workspace) so the essentials
            # glyphs align with the folder icons at column 0.
            label = Text(f"{glyph}  {name}", style=essentials_style)
            tree.root.add_leaf(label, data=_EssentialsMarker())

        # Section break below essentials, separating from tab folders.
        tree.root.add_leaf(Text("\u2800"), data=_SpacerMarker())

        f = self.filter_text.strip().lower()

        group_color = (
            self._omarchy_colors.get("accent")
            or self._omarchy_colors.get("color4")
            or "cyan"
        )
        group_style = Style(color=group_color, bold=True)

        # Pair each saved row with the first live tab sharing its URL
        # (walking self._live, which is stable first-seen order). The
        # paired chromium tab_id is stored on the saved Row so
        # render_label can resolve the "you are here" highlight against
        # that specific tab — when three Yahoo tabs are open and one is
        # saved, only the paired one (saved row) OR one of the two
        # unpaired loose leaves lights up, never two at once.
        # saved_urls dedups by URL (store.add_saved already dedups, so
        # this is just a set-comprehension convenience).
        saved_urls = {s.url for s in self._saved}
        paired_tab_id_by_url: dict[str, str] = {}
        consumed_tab_ids: set[str] = set()
        for t in self._live:
            if t.url in saved_urls and t.url not in paired_tab_id_by_url:
                paired_tab_id_by_url[t.url] = t.id
                consumed_tab_ids.add(t.id)
        groups: dict[str, list[store.SavedTab]] = {}
        for t in self._saved:
            if not _match(t.title, t.url, f):
                continue
            groups.setdefault(t.group or "Unsorted", []).append(t)

        self._saved_nodes = {}
        for group_name in sorted(groups):
            items = groups[group_name]
            gnode = tree.root.add(
                Text(
                    f"Saved: {group_name} ({len(items)})",
                    style=group_style,
                ),
                expand=True,
                data=_GroupMarker(),
            )
            self._saved_nodes[group_name] = gnode
            for s in items:
                row = Row(
                    kind="saved",
                    title=s.title,
                    url=s.url,
                    group=s.group,
                    # Paired chromium tab_id (or "" if no open tab for
                    # this URL yet). render_label matches against this
                    # so the highlight stays on just the paired tab.
                    tab_id=paired_tab_id_by_url.get(s.url, ""),
                )
                gnode.add_leaf(_format_row(row), data=row)

        # Unsaved open tabs render as top-level leaves below the saved
        # groups — same shape as the Essentials rows, each tab on its
        # own parent (the tree root) with no "Open Tabs" header branch.
        # Tabs consumed by the saved-row pairing above are skipped here
        # so duplicate open windows for a saved site still show, but
        # the one paired copy doesn't render twice.
        live_unsaved = []
        for t in self._live:
            if t.id in consumed_tab_ids:
                continue
            if not _match(t.title, t.url, f):
                continue
            live_unsaved.append(t)
        if live_unsaved:
            # Divider between saved groups and unsaved open tabs — a dim
            # horizontal rule rather than the blank braille used for the
            # Workspace/Essentials/Saved breaks, because this boundary
            # separates two different *kinds* of rows (folders above,
            # loose leaves below) and benefits from a visible cue.
            # Width is baked at rebuild time; on_resize already calls
            # _rebuild_tree so the rule re-stretches on window changes.
            # Fallback width (80) covers the first rebuild before layout
            # has run. Styled as a ghost rule (0.1 opacity — well below
            # the preview-tier 0.35) so it barely lifts off the
            # background; the eye registers the boundary without the
            # line competing with any row for attention.
            divider_width = max(1, (tree.size.width or 80) - 2)
            divider_style = Style(color=self._faded_fg(0.1))
            tree.root.add_leaf(
                Text("\u2500" * divider_width, style=divider_style),
                data=_SpacerMarker(),
            )
            for t in live_unsaved:
                row = Row(kind="live", title=t.title, url=t.url, tab_id=t.id)
                tree.root.add_leaf(_format_row(row), data=row)

        # Restore cursor onto the same URL the user was on, if it still
        # exists after the rebuild. _saved_nodes plus the root's direct
        # children (unsaved open tabs) give us a fast path; if the URL
        # no longer matches any leaf (tab closed,
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

    def _restore_cursor(self, tree: Tree, url: str, kind: str) -> None:
        # Unsaved open tabs are direct children of tree.root (no Open
        # Tabs header branch anymore), so look for "live" rows there
        # first. Saved leaves still live under their group branches.
        if kind == "live":
            for leaf in tree.root.children:
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
        # Inline rename swallows every key except Esc. Enter commits; Backspace
        # deletes before the cursor; Delete deletes at the cursor; Left/Right/
        # Home/End move the cursor within the buffer; printable chars insert at
        # the cursor. All other keys are consumed silently so stray presses
        # can't scroll away or activate another row mid-edit. Esc falls
        # through to action_quit_to_browser, whose top tier clears rename
        # state — same shape as search's Esc-cancel path.
        if self._rename_url is not None:
            k = event.key
            if k == "escape":
                return
            if k == "enter":
                self._commit_rename()
                event.stop()
                return
            buf = self._rename_buffer
            cur = self._rename_cursor
            if k == "backspace":
                if cur > 0:
                    self._rename_buffer = buf[:cur - 1] + buf[cur:]
                    self._rename_cursor = cur - 1
                self._rename_repaint()
                event.stop()
                return
            if k == "delete":
                if cur < len(buf):
                    self._rename_buffer = buf[:cur] + buf[cur + 1:]
                self._rename_repaint()
                event.stop()
                return
            if k == "left":
                self._rename_cursor = max(0, cur - 1)
                self._rename_repaint()
                event.stop()
                return
            if k == "right":
                self._rename_cursor = min(len(buf), cur + 1)
                self._rename_repaint()
                event.stop()
                return
            if k in ("home", "ctrl+a"):
                self._rename_cursor = 0
                self._rename_repaint()
                event.stop()
                return
            if k in ("end", "ctrl+e"):
                self._rename_cursor = len(buf)
                self._rename_repaint()
                event.stop()
                return
            ch = event.character or ""
            if len(ch) == 1 and ch.isprintable():
                self._rename_buffer = buf[:cur] + ch + buf[cur:]
                self._rename_cursor = cur + 1
                self._rename_repaint()
                event.stop()
                return
            event.stop()
            return
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

    # All motion actions short-circuit during inline rename. on_key consumes
    # printable chars (j/k/g/G/h/l) with event.stop(), but arrow keys and
    # Ctrl combos (left/right/up/down/Home/End/Ctrl+D/Ctrl+U/PageUp/PageDown)
    # come in as non-printable key events that — in this Textual version —
    # still reach the binding layer despite the on_key stop(), which would
    # otherwise scroll the cursor away or collapse the parent group while
    # the user is editing the row's label. Gating here is belt-and-suspenders.

    def action_cursor_down(self) -> None:
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        tree.action_cursor_down()
        self._skip_spacers(tree, +1)

    def action_cursor_up(self) -> None:
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        tree.action_cursor_up()
        self._clamp_help_cursor(tree)
        self._skip_spacers(tree, -1)

    def action_jump_top(self) -> None:
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        tree.cursor_line = _HELP_FIRST_ROW if self._in_help_mode else 0
        self._skip_spacers(tree, +1)

    def action_jump_bottom(self) -> None:
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        tree.cursor_line = max(0, tree.last_line)
        self._skip_spacers(tree, -1)

    def action_half_page_down(self) -> None:
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        step = max(1, tree.size.height // 2)
        for _ in range(step):
            tree.action_cursor_down()
        self._skip_spacers(tree, +1)

    def action_half_page_up(self) -> None:
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        step = max(1, tree.size.height // 2)
        for _ in range(step):
            tree.action_cursor_up()
        self._clamp_help_cursor(tree)
        self._skip_spacers(tree, -1)

    def _clamp_help_cursor(self, tree: Tree) -> None:
        # In help mode rows 0 and 1 are the title and its spacer — they
        # shouldn't take cursor focus. After any upward motion, snap back
        # down if we've landed on them.
        if self._in_help_mode and tree.cursor_line < _HELP_FIRST_ROW:
            tree.cursor_line = _HELP_FIRST_ROW

    def _skip_spacers(self, tree: Tree, direction: int) -> None:
        """Advance the cursor past any `_SpacerMarker` leaf in `direction`
        (+1 = down, -1 = up) so motion never parks on a blank row. Runs
        after every motion action in the main tree. Skipped in help mode,
        where the row at `_HELP_FIRST_ROW` is a braille-blank *by design*
        (cursor floor — `_clamp_help_cursor` owns it). If we're already
        at the boundary and can't step past the spacer, reverse direction
        so the cursor always lands on a real row instead of getting stuck
        on the last spacer in the tree."""
        if self._in_help_mode:
            return
        seen_boundary = False
        while True:
            node = tree.cursor_node
            if node is None or not isinstance(node.data, _SpacerMarker):
                return
            prev_line = tree.cursor_line
            if direction > 0:
                tree.action_cursor_down()
            else:
                tree.action_cursor_up()
            if tree.cursor_line == prev_line:
                # Hit the top/bottom while still on a spacer — reverse
                # once and retry so we exit via the other side instead
                # of leaving the cursor parked on a blank.
                if seen_boundary:
                    return
                seen_boundary = True
                direction = -direction

    def action_collapse(self) -> None:
        # During inline rename the Left arrow moves the edit cursor; the
        # binding must not collapse the parent group out from under the
        # row being edited (which also hides the inline edit field).
        if self._rename_url is not None:
            return
        self._activate_cursor()
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
        if self._rename_url is not None:
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        if node.allow_expand and not node.is_expanded:
            node.expand()

    def action_focus_search(self) -> None:
        # Every action bound to a printable key needs a rename-mode gate:
        # on_key's printable branch already inserts the char into the
        # buffer, but Textual in this version still fires the App-level
        # binding in parallel (same leak as arrow keys → action_collapse).
        # Without the gate, pressing `/`, `o`, `s`, `d`, `p`, `P`, `r`, `?`
        # mid-edit would double-fire the action and, e.g., open a tab or
        # reset the rename buffer on top of the user's keystroke.
        if self._rename_url is not None:
            return
        if self._in_help_mode:
            return
        self._in_search_mode = True
        self._cursor_on = True
        self._rebuild_tree()

    def action_activate(self) -> None:
        if self._rename_url is not None:
            return
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
                return
            self._mark_active(row.url, row.tab_id)
        else:
            self._open_saved(row)

    def action_open_saved(self) -> None:
        if self._rename_url is not None:
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._open_saved(row)

    def _activate_saved(self, row: Row, *, raise_window: bool) -> str:
        """Activate `row` in chromium and return the tab_id actually
        hit. Uses `row.tab_id` directly when _rebuild_tree has already
        paired the saved row with an open chromium tab; otherwise
        falls back to `actions.open_or_switch` which finds-or-creates
        by URL. The direct-id path matters because `cdp.list_tabs()`
        (used by open_or_switch → find_by_url) returns tabs in
        chromium's MRU order, which can differ from bm's stable
        first-seen pairing — activating the MRU match would land
        chromium on a tab that bm considers "loose", so the highlight
        would jump to a leaf instead of the saved row the user just
        opened."""
        if row.tab_id:
            cdp.activate(row.tab_id)
            if raise_window:
                actions.raise_chromium()
            return row.tab_id
        return actions.open_or_switch(row.url, raise_window=raise_window)

    def _open_saved(self, row: Row) -> None:
        try:
            tab_id = self._activate_saved(row, raise_window=True)
        except Exception as exc:
            self._set_status(f"Failed to open ({exc})")
            return
        self._mark_active(row.url, tab_id)
        self._refresh_live()

    def _mark_active(self, url: str, tab_id: str = "") -> None:
        """Record `url` (and optionally the chromium `tab_id` it
        resolved to) as the currently-active tab, and refresh the tree
        so FolderTree.render_label repaints the matching row with
        `color5`. Called from every activation path: Enter, `o`, `p`,
        preview-mode cursor moves (via _peek_row), and the external
        cycle (_cycle_step also goes through _peek_row).

        `tab_id` disambiguates duplicate live tabs sharing a URL. Pass
        `""` when the caller doesn't know it; saved rows still match
        by URL inside render_label, loose live rows never do.
        """
        if self._active_url == url and self._active_tab_id == tab_id:
            return
        self._active_url = url
        self._active_tab_id = tab_id
        # Full tree rebuild is the simplest way to get both the old and
        # new active rows to repaint. Cheap in practice.
        self._rebuild_tree()

    def action_save_selected(self) -> None:
        # Save the tab highlighted in the TUI — NOT chromium's active tab.
        # The CLI's `bm save` still uses actions.save_focused() for the
        # "save whatever chromium is showing right now" workflow (useful
        # from a hyprland keybind without opening bm). In the TUI, the
        # user has a cursor; respect it.
        if self._rename_url is not None:
            return
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
        if self._rename_url is not None:
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None or row.kind != "saved":
            return
        if store.remove_saved(row.url):
            self._set_status("Removed Tab")
            self._load_all()

    def action_rename_saved(self) -> None:
        # Re-entering rename during rename would reset the buffer to the
        # row's stored title — so if the user has typed `r` as a normal
        # char mid-edit, the binding leak mustn't overwrite their work.
        if self._rename_url is not None:
            return
        if self._in_help_mode or self._in_search_mode:
            return
        row = self._selected_row()
        if row is None or row.kind != "saved":
            return
        self._rename_url = row.url
        self._rename_buffer = row.title
        # Start the insertion cursor at the end of the title — matches the
        # natural "append-first" edit flow (most common case: user wants to
        # tweak or replace the trailing portion). Home/Ctrl+A jumps to the
        # start when they'd rather edit from the front.
        self._rename_cursor = len(row.title)
        self._cursor_on = True
        # Full rebuild (not just _invalidate) on entry so the edit-mode
        # label lands on the row immediately. _invalidate is enough for
        # subsequent per-keystroke repaints since only the one row's
        # label text changes.
        self._rebuild_tree()

    def _rename_repaint(self) -> None:
        """Called after any rename-buffer or cursor change. Resets the blink
        phase to on (so the cursor is visible right after the keystroke) and
        invalidates the tree so render_label repaints the row."""
        self._cursor_on = True
        self.query_one("#tree", FolderTree)._invalidate()

    def _commit_rename(self) -> None:
        """Persist the buffered title and exit rename mode. No-op on empty
        buffer — empty titles would leave the row unlabeled, and cancelling
        via Esc is always available if that's what the user wanted."""
        url = self._rename_url
        if url is None:
            return
        new_title = self._rename_buffer.strip()
        self._rename_url = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        # Arm a 500ms suppression window so the NodeSelected that Tree's
        # own enter-binding posts in parallel with this commit doesn't
        # also activate the tab. The window auto-expires — no callback
        # race with the message pump.
        self._suppress_activate_until = time.monotonic() + 0.5
        if new_title and store.rename_saved(url, new_title):
            self._set_status("Renamed Tab")
            self._load_all()
        else:
            # Empty buffer or URL not found — just redraw the row without
            # the editable field. _load_all would also work but this is
            # lighter and avoids a CDP round-trip for a no-op. Status bar
            # also needs a refresh so `[rename]` drops (and `[preview]`
            # returns if that mode was active).
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()

    def _cancel_rename(self) -> None:
        self._rename_url = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        self.query_one("#tree", FolderTree)._invalidate()
        # Drop `[rename]` from the status bar; `[preview]` comes back if
        # that mode was active before the user entered rename.
        self._update_search_tree()

    def action_quit_to_browser(self) -> None:
        if self._rename_url is not None:
            self._cancel_rename()
            return
        if self._in_search_mode:
            self._in_search_mode = False
            self.filter_text = ""
            self._rebuild_tree()
            return
        if self._help_visible():
            self._set_help(False)
            return
        # Esc-to-park: if the hover-dim overlay is currently visible,
        # the first Esc just parks the cursor (hides the dim, preserves
        # cursor_line). A second Esc — with the cursor already parked
        # and no other modal state to dismiss — falls through to the
        # real close path below. This gives a clean "cancel navigation,
        # then close" flow instead of Esc immediately tearing down bm.
        tree = self.query_one("#tree", FolderTree)
        if tree.cursor_active:
            tree.cursor_active = False
            return
        # bm and chromium are paired — closing one closes the other.
        launcher.close_chromium()
        self.exit()

    def _activate_cursor(self) -> None:
        """Reactivate the hover-dim overlay after Esc has parked the
        cursor. Called from every motion action (j/k/↑/↓/g/G/Ctrl+D/U/
        h/l) so any user-driven navigation restores the visual cursor.
        Deliberately NOT called from action keys (Enter/o/s/d/r/p/P):
        those act on the current cursor_line whether visible or not —
        acting without seeing the cursor is the user's choice, and
        lighting up a row just before tearing it out of the tree (e.g.
        `d`elete) or activating a tab (Enter, o) would flash without
        purpose."""
        tree = self.query_one("#tree", FolderTree)
        if not tree.cursor_active:
            tree.cursor_active = True

    def action_show_help(self) -> None:
        if self._rename_url is not None:
            return
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
        if self._rename_url is not None:
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._peek_row(row)

    def action_toggle_preview(self) -> None:
        if self._rename_url is not None:
            return
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
        if self._rename_url is not None:
            # Still in rename mode — Enter is owned by the rename handler.
            return
        if time.monotonic() < self._suppress_activate_until:
            # Inside the post-commit suppression window. The NodeSelected
            # posted by Tree's own enter-binding would otherwise activate
            # the tab right after renaming it (user hits Enter once,
            # expecting "save the new title," and bm both saves AND
            # opens the tab).
            return
        if isinstance(event.node.data, Row):
            self.action_activate()

    def on_tree_node_highlighted(self, event) -> None:
        # Fires on every cursor-line change within any Tree. We only care
        # about the main tree; the search-tree doesn't have highlightable
        # rows in a meaningful sense.
        #
        # Rename lockdown: during inline rename, Textual's Tree widget has
        # its own up/down arrow bindings that manipulate cursor_line
        # directly, bypassing our App-level gates. If the user hits up/down
        # mid-edit, the cursor would drift to a sibling row (taking the
        # edit UI with it, since render_label keys off the row's URL).
        # Snap it back to the row being renamed so the edit field stays
        # put and the user's keystrokes keep landing on the right tab.
        if self._rename_url is not None:
            node = event.node
            if not (
                isinstance(node.data, Row)
                and node.data.url == self._rename_url
            ):
                self._restore_rename_cursor()
            return
        if self._in_preview_mode and not self._in_help_mode:
            self._schedule_preview()

    def _restore_rename_cursor(self) -> None:
        """Walk the saved-group nodes and move the tree cursor back onto
        the row whose URL matches `_rename_url`. No-op if the row isn't
        present (shouldn't happen during an active edit, but keeps this
        safe against mid-flight rebuilds)."""
        tree = self.query_one("#tree", Tree)
        for gnode in self._saved_nodes.values():
            for leaf in gnode.children:
                if (
                    isinstance(leaf.data, Row)
                    and leaf.data.url == self._rename_url
                ):
                    tree.move_cursor(leaf)
                    return

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
        active_tab_id = ""
        try:
            if row.kind == "live":
                cdp.activate(row.tab_id)
                active_tab_id = row.tab_id
            else:
                active_tab_id = self._activate_saved(row, raise_window=False)
        except Exception as exc:
            self._set_status(f"Peek failed ({exc})")
            return
        self._mark_active(row.url, active_tab_id)
        # Refresh _live so the saved row that just opened a new tab
        # gets paired with it immediately — render_label needs the
        # saved Row's tab_id to match _active_tab_id for the color11
        # highlight, and without this call that pairing waits until
        # the next 3-second _refresh_live tick. Matches _open_saved's
        # ordering. Skip for live peeks (the tab already exists in
        # self._live so no refresh is needed).
        if row.kind == "saved":
            self._refresh_live()
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


def run_tui() -> None:
    import atexit, sys
    # Normal quit (Esc/q) → action_quit_to_browser handles it.
    # sys.exit / Textual's exit path → atexit.
    # Super+W / window close → ghostty dies, bm-py gets SIGHUP. atexit
    # does not fire for SIGHUP/SIGTERM, so install signal handlers too.
    def _cleanup() -> None:
        launcher.close_chromium()
        # Remove our PID file so the next `bm next`/`bm prev` press
        # doesn't signal a dead process (or worse, a reused PID).
        try:
            PID_FILE.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    atexit.register(_cleanup)

    def _term(_signum, _frame):
        _cleanup()
        sys.exit(0)

    for sig in (signal.SIGHUP, signal.SIGTERM):
        try:
            signal.signal(sig, _term)
        except (ValueError, OSError):
            pass
    BmApp().run()
