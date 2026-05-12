from dataclasses import dataclass
from typing import Optional
import asyncio
import json
import os
import signal
import subprocess
import time
from urllib.parse import urlsplit

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
from .paths import CHROMIUM_PID, PID_FILE, ensure_dirs


def _fast_close_and_exit() -> None:
    """Kill the bm-managed chromium directly by PID, drop the bm pidfile,
    and `os._exit(0)`. The single fast-shutdown path used by every bm
    teardown trigger — q/Esc keybinds, hyprland's closewindow event for
    Super+W, and SIGHUP/SIGTERM signal handlers all funnel through this.
    Skips launcher.close_chromium's CDP teardown (httpx + per-tab
    /json/close + PID-exit poll up to 3s) and Textual's exit machinery
    in favor of: SIGTERM the chromium pid, sleep 1.0s for chromium's own
    graceful-exit handler to run (cookies flush + session writes), then
    SIGKILL anything that didn't die. os._exit bypasses atexit so we
    don't re-enter the slow CDP path that this helper exists to avoid.
    """
    cpid: Optional[int] = None
    try:
        cpid_text = CHROMIUM_PID.read_text().strip()
        cpid = int(cpid_text) if cpid_text else None
    except (FileNotFoundError, ValueError, OSError):
        pass
    if cpid is not None:
        try:
            os.kill(cpid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        time.sleep(1.0)
        try:
            os.kill(cpid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
    try:
        PID_FILE.unlink()
    except (FileNotFoundError, OSError):
        pass
    os._exit(0)

REFRESH_SECONDS = 0.3


@dataclass
class Row:
    """Selectable row in the tree — either a live CDP tab or a saved tab."""
    kind: str  # "live" or "saved"
    title: str
    url: str
    group: str = ""
    tab_id: str = ""  # chromium tab id (paired live tab for saved rows)
    # Stable saved-tab id (uuid hex from saved-tabs.json). Empty for live
    # rows. Session pairing, rename / delete / move / url-edit dispatch,
    # and render-path matching all key on this — duplicate URLs anywhere
    # in saved-tabs.json (across groups or within one) stay distinguished.
    id: str = ""


class _SearchMarker:
    """Sentinel data on the search-leaf so actions know to skip it."""


class _WorkspaceMarker:
    """Sentinel data on the Workspace leaf — used by FolderTree.render_label
    to apply a dim overlay when the cursor lands on this row."""


# Magic group name that renders as parent-level cyan leaves (no folder
# header) instead of a Saved: header + indented children. Tabs with this
# group still go through the normal SavedTab schema and all the standard
# actions (rename, delete, activate, peek, cycle, highlight, pairing).
ESSENTIALS_GROUP = "Essentials"


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

    # Same blend, applied to saved tab leaves that aren't currently
    # paired with a live chromium tab — i.e., the saved entry exists
    # but the URL isn't open right now. Slightly lighter than the
    # cursor hover so a cursor landing on an unpaired row is still
    # visually distinguishable (cursor adds a second blend on top).
    UNPAIRED_DIM_FACTOR = 0.4

    # Esc-park state. When False, render_label stops treating any row
    # as the cursor, so the hover-dim overlay disappears. cursor_line
    # is preserved untouched — motion actions flip this back to True
    # and resume from where the user left off.
    cursor_active: reactive[bool] = reactive(True)

    # Flash-dim on arrival at the active "you are here" row. The active
    # row resists the regular hover-dim so the highlight reads as a
    # constant beacon, which hides the "cursor just landed here" motion
    # cue every other row provides by dimming. ACTIVE_DIM_FLASH_S is a
    # brief confirmation flash: on arrival, dim immediately; after the
    # timer fires, restore to full color11. Net effect: a quick fade-in-
    # fade-out on the active row whenever the cursor lands on it,
    # without permanently washing out the highlight. _dim_active_row is
    # the flag render_label reads; _dim_active_timer holds the pending
    # Timer that clears the flash; _dim_active_key ((row.url, row.id,
    # row.tab_id) of the cursor node) lets _reevaluate short-circuit
    # when the logical row under the cursor hasn't changed — so a
    # _rebuild_tree cycle that re-seats the cursor on the same row via
    # _restore_cursor doesn't re-trigger the flash. Keying on id(node)
    # would miss this because rebuild creates fresh node instances for
    # the same row. row.id (SavedTab.id) joins the key so duplicate
    # URLs each have their own identity.
    ACTIVE_DIM_FLASH_S = 0.18
    _dim_active_row: bool = False
    _dim_active_timer = None
    _dim_active_key = None
    # Per-call observation of (_active_tab_id, cursor row's url) so
    # _reevaluate can tell which side of the pairing just changed.
    # The flash should only fire when the *cursor* moves onto the
    # already-active row, not when the row the cursor's already on
    # *becomes* active (Enter/o/peek/external cycle) — the user just
    # triggered the activation and doesn't need a "you moved here"
    # cue for motion they didn't perform.
    _last_active_tab_id: str = ""
    # Identity of the row the cursor was last seen on. Tuple of
    # (url, saved_id, tab_id) so duplicate URLs (saved-tabs.json now
    # allows them) don't collapse to the same key — a URL alone would
    # report `cursor_moved=False` when the cursor steps between two
    # same-URL rows. None when no Row is under the cursor.
    _last_cursor_key = None
    # Set by BmApp._rebuild_tree so _reevaluate_active_dim short-
    # circuits while the tree is being rebuilt. Textual's base Tree
    # internally reassigns `cursor_line = cursor_node._line` during
    # its _build phase (after add_leaf invalidates the line cache —
    # see _request_dim_repaint's note); with `always_update=True`
    # that fires watch_cursor_line and our _reevaluate runs while
    # the cursor sits on whatever transient row line N points to in
    # the half-built new tree. Updating the diff anchors there
    # consumes the active_changed signal before _restore_cursor has
    # placed the cursor on the real target, so the eventual landing
    # reads as `active_changed=False` and the flash misfires. With
    # this flag, no anchor work happens during the rebuild — the
    # post-rebuild explicit reeval (queued via call_after_refresh)
    # is the single transition observation.
    _suspend_dim_eval: bool = False

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
        self._reevaluate_active_dim()

    def watch_cursor_line(self, previous_line: int, line: int) -> None:
        # Base Tree.watch_cursor_line does load-bearing work (updates
        # `_cursor_node`, flips per-node `_selected`, refreshes the
        # old/new cursor rows) — must super() first or cursor tracking
        # breaks. After the base runs, cursor_node reflects the new
        # line so _reevaluate can compare against the active row.
        # `always_update=True` on the base reactive means this fires
        # on every assignment, including the same-value reseat during
        # _rebuild_tree's _restore_cursor path, which is exactly when
        # we want to reconsider the dim state.
        super().watch_cursor_line(previous_line, line)
        self._reevaluate_active_dim()

    def _reevaluate_active_dim(self) -> None:
        """Trigger or clear the flash-dim on the active-tab row. Called
        on cursor moves, Esc-park toggles, and implicitly after tree
        rebuilds (via watch_cursor_line firing when _restore_cursor
        re-seats cursor_line). Short-circuits when the logical row
        under the cursor is unchanged — so a rebuild that re-seats the
        cursor on the same row doesn't re-trigger the flash, and a
        completed flash stays cleared while the cursor still sits on
        that row."""
        if self._suspend_dim_eval:
            return
        app = self.app
        cur = self.cursor_node
        # Per-workspace displayed-active id, not the global chromium
        # focus — see BmApp._displayed_active_tab_id.
        get_displayed = getattr(app, "_displayed_active_tab_id", None)
        active_tab_id = get_displayed() if callable(get_displayed) else getattr(app, "_active_tab_id", "")
        on_active = (
            self.cursor_active
            and cur is not None
            and bool(active_tab_id)
            and isinstance(cur.data, Row)
            and cur.data.tab_id == active_tab_id
        )
        # Diff against the previous observation to attribute this
        # transition to either a cursor move or an active-tab swap.
        # Updated unconditionally (before the key-based short-circuit)
        # so the "last" values always reflect the most recent call,
        # not the most recent call that did real work.
        cur_cursor_key = (
            (cur.data.url, cur.data.id, cur.data.tab_id)
            if cur is not None and isinstance(cur.data, Row)
            else None
        )
        cursor_moved = self._last_cursor_key != cur_cursor_key
        active_changed = self._last_active_tab_id != active_tab_id
        self._last_active_tab_id = active_tab_id
        self._last_cursor_key = cur_cursor_key

        key = (cur.data.url, cur.data.id, cur.data.tab_id) if on_active else None
        if key == self._dim_active_key:
            return
        # Key changed — either cursor just landed on the active row,
        # or just left it. In either direction, cancel any pending
        # flash and repaint if we were mid-dim.
        if self._dim_active_timer is not None:
            self._dim_active_timer.stop()
            self._dim_active_timer = None
        needs_repaint = self._dim_active_row
        self._dim_active_row = False
        self._dim_active_key = key
        # Only flash on the "cursor moved onto an already-active row"
        # transition. When the active tab changed this tick (Enter/o/
        # peek/external cycle all set `_active_tab_id` → _rebuild_tree
        # → _restore_cursor re-seats cursor_line → we land here with
        # `active_changed=True`), the user drove the activation and
        # doesn't need a "you're here" flash for motion they didn't
        # perform. `not active_changed` filters that out; `cursor_moved`
        # gates on the cursor genuinely having moved, so a watcher
        # firing spuriously on the same row stays quiet. Preview mode
        # suppresses the flash entirely: every cursor landing already
        # triggers a peek + `_mark_active` which repaints the row with
        # the color11 highlight — the color change itself is the
        # motion cue, so adding a dim blip on oscillations that happen
        # to land back on the lagging active row just reads as a
        # glitch.
        in_preview = getattr(app, "_in_preview_mode", False)
        if on_active and cursor_moved and not active_changed and not in_preview:
            self._dim_active_row = True
            self._dim_active_timer = self.set_timer(
                self.ACTIVE_DIM_FLASH_S, self._clear_active_dim
            )
            needs_repaint = True
        if needs_repaint:
            self._request_dim_repaint()

    def _clear_active_dim(self) -> None:
        # Flash timer expired — drop the dim and repaint so the row
        # snaps back to full color11.
        self._dim_active_timer = None
        self._dim_active_row = False
        self._request_dim_repaint()

    def _request_dim_repaint(self) -> None:
        # Can't call `_invalidate()` directly here: base Tree._build
        # reassigns `cursor_line` to `cursor_node._line` after
        # populating `_tree_lines_cached` (see Textual's _tree.py
        # around line 1294). With `always_update=True` that fires
        # watch_cursor_line → our _reevaluate → this repaint path,
        # and `_invalidate` zeroes out `_tree_lines_cached` mid-build.
        # The property assertion right after _build returns then
        # trips on the cleared cache (AssertionError in _on_idle).
        # Deferring via call_after_refresh pushes the invalidate out
        # of the current synchronous call stack — _build completes
        # cleanly, the deferred invalidate runs, and the next render
        # cycle picks up the new _dim_active_row flag.
        self.call_after_refresh(self._invalidate)

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

    def _unpaired_color(self, fg_hex):
        """Same shape as _hover_color but with UNPAIRED_DIM_FACTOR —
        used to fade saved rows that aren't currently open in chromium."""
        bg_hex = self.app._omarchy_colors.get("background")
        try:
            return Color.parse(fg_hex).blend(
                Color.parse(bg_hex), self.UNPAIRED_DIM_FACTOR
            ).hex
        except Exception:
            return fg_hex

    def render_label(self, node, base_style, style):
        label = super().render_label(node, base_style, style)
        app = self.app
        colors = app._omarchy_colors
        # Inline edit modes — return early with a custom buffer label
        # when this row owns the active edit. Four shapes share one
        # buffer renderer (_render_edit_label):
        #   - saved/live tab rename: glyph + "  " + buffer
        #   - group rename: folder-glyph + "  Saved: " + buffer
        #   - new-group preview: folder-glyph + "  Saved: " + buffer
        # The folder-glyph variant matches the regular group-header
        # paint so the row reads as "still a header, just editable."
        # Rename target match: live rows are keyed by chromium tab_id
        # (unique per tab); saved rows are keyed by SavedTab.id (unique
        # per row — duplicate URLs are now allowed anywhere in
        # saved-tabs.json, so URL alone is no longer enough). Both gated
        # by kind.
        if (
            app._rename_url is not None
            and isinstance(node.data, Row)
            and node.data.kind == app._rename_kind
            and (
                (
                    app._rename_kind == "live"
                    and node.data.tab_id == app._rename_tab_id
                )
                or (
                    app._rename_kind == "saved"
                    and node.data.id == app._rename_saved_id
                )
            )
        ):
            return self._render_edit_label(
                prefix=f"{_glyph(node.data.url)}  ",
                buffer=app._rename_buffer,
                cursor=app._rename_cursor,
                cursor_on=app._cursor_on,
                colors=colors,
            )
        # URL edit is saved-only — match on SavedTab.id (URL would
        # collide with same-URL siblings; live rows reject `e` upstream
        # but the kind check is belt-and-suspenders).
        if (
            app._url_edit_saved_id is not None
            and isinstance(node.data, Row)
            and node.data.kind == "saved"
            and node.data.id == app._url_edit_saved_id
        ):
            # URL edit shares the same buffer/cursor as rename and
            # paints with the same glyph + "  " prefix; only the
            # commit handler differs (writes the URL field instead
            # of the title).
            return self._render_edit_label(
                prefix=f"{_glyph(node.data.url)}  ",
                buffer=app._rename_buffer,
                cursor=app._rename_cursor,
                cursor_on=app._cursor_on,
                colors=colors,
            )
        rename_group = app._rename_group
        if (
            rename_group is not None
            and isinstance(node.data, _GroupMarker)
            and app._saved_nodes.get(rename_group) is node
        ):
            glyph = self._FOLDER_OPEN if node.is_expanded else self._FOLDER_CLOSED
            return self._render_edit_label(
                prefix=f"{glyph}  ",
                buffer=app._rename_buffer,
                cursor=app._rename_cursor,
                cursor_on=app._cursor_on,
                colors=colors,
            )
        if (
            app._pending_new_group_row is not None
            and isinstance(node.data, _GroupMarker)
            and app._saved_nodes.get("") is node
        ):
            glyph = self._FOLDER_OPEN if node.is_expanded else self._FOLDER_CLOSED
            return self._render_edit_label(
                prefix=f"{glyph}  ",
                buffer=app._rename_buffer,
                cursor=app._rename_cursor,
                cursor_on=app._cursor_on,
                colors=colors,
            )
        # Workspace row inline edits: rename current workspace, or
        # preview-before-commit a brand-new one. Both write the buffer
        # over the Workspace label; prefix is the same braille-blank
        # left margin the static label uses so layout stays stable.
        if (
            isinstance(node.data, _WorkspaceMarker)
            and (
                app._rename_workspace_id is not None
                or app._pending_new_workspace
            )
        ):
            return self._render_edit_label(
                prefix="⠀",
                buffer=app._rename_buffer,
                cursor=app._rename_cursor,
                cursor_on=app._cursor_on,
                colors=colors,
            )
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
        # Per-workspace displayed-active id — see
        # BmApp._displayed_active_tab_id for why this isn't just
        # `_active_tab_id` (global chromium focus).
        get_displayed = getattr(app, "_displayed_active_tab_id", None)
        active_tab_id = get_displayed() if callable(get_displayed) else getattr(app, "_active_tab_id", "")
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
        dim = False
        if isinstance(node.data, _WorkspaceMarker):
            src = colors.get("accent") or colors.get("color4") or "#cccccc"
            bold = True
        elif isinstance(node.data, _GroupMarker):
            src = colors.get("accent") or colors.get("color4") or "cyan"
            bold = True
        elif isinstance(node.data, Row):
            if is_selected:
                src = colors.get("color11") or "#E5C736"
            elif node.data.group == ESSENTIALS_GROUP:
                # Essentials are top-level cyan leaves (no folder header).
                # Detect via group name rather than a marker class so the
                # data-driven path stays the single source of truth.
                src = colors.get("color6") or colors.get("secondary") or "#cccccc"
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
            # Saved rows without a paired live tab read as "saved but
            # not open right now" — fade the source color toward bg
            # before any cursor-hover blend so users can tell at a
            # glance which entries are currently open in chromium.
            # Pairing populates tab_id in _rebuild_tree; an empty
            # tab_id on a saved row means the URL isn't live. Active
            # rows can't reach this branch (is_selected requires a
            # matching tab_id, which by definition means paired).
            if node.data.kind == "saved" and not node.data.tab_id:
                src = self._unpaired_color(src)
        if src is not None:
            # The active "you are here" tab normally keeps its full
            # color11 under the cursor so the highlight reads as a
            # constant beacon rather than a dim blend. But arriving
            # on the active row gives no motion cue ("did my cursor
            # actually land there?") because color11 doesn't change.
            # `_dim_active_row` is a brief on-arrival flash flipped
            # True by `_reevaluate_active_dim` and cleared by its
            # ACTIVE_DIM_FLASH_S timer — a quick fade-in-fade-out that
            # confirms the landing without permanently washing out
            # the highlight. Preview mode suppresses dim ONLY on Row
            # (tab leaf) nodes: every cursor landing on a tab drives
            # a peek + `_mark_active` that repaints the row to color11
            # within ~100 ms, so the color transition is the motion
            # cue and a hover-dim blip on the row that's about to
            # light up just reads as visual noise. Workspace/group
            # headers don't get peeked, so they keep the hover dim in
            # preview mode — otherwise the cursor would look invisible
            # on them and motion through the tree would feel like it
            # skipped those rows.
            in_preview = getattr(app, "_in_preview_mode", False)
            suppress_dim = in_preview and isinstance(node.data, Row)
            dim = (
                is_cursor
                and (not is_selected or self._dim_active_row)
                and not suppress_dim
            )
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

        # Group-header branches: prepend the folder glyph. Reuses the
        # same `dim` boolean computed above so the icon's dim state
        # stays in lockstep with the text — keying on raw `is_cursor`
        # here would ignore the preview-mode suppression (for Row
        # nodes) and the _dim_active_row flash logic, producing a
        # half-dimmed row where only the icon fades.
        if isinstance(node.data, _GroupMarker):
            glyph = self._FOLDER_OPEN if node.is_expanded else self._FOLDER_CLOSED
            # Filter tint only when the filter is *visibly* doing
            # something: the folder is open (closed folders can't
            # express "I'm showing only the open children"), AND at
            # least one paired child is rendered. The empty-filtered
            # case (filter set, no chromium-paired tabs) reads visually
            # the same as a normal empty/closed folder, so the brighter
            # tint there only confuses — fall back to the accent.
            visibly_filtered = (
                node.is_expanded
                and self._is_group_filtered(node)
                and len(node.children) > 0
            )
            if visibly_filtered:
                icon_src = self._filter_icon_color(colors)
            else:
                icon_src = colors.get("accent") or colors.get("color4") or "cyan"
            icon_color = self._hover_color(icon_src) if dim else icon_src
            # Text always uses the regular accent so the filter cue
            # stays scoped to the icon. Build the label fresh with
            # explicit per-segment styles instead of concatenating
            # styled Text instances — Rich's __add__ inherits the
            # first operand's default style, which was bleeding the
            # icon's filter color onto the group text on filtered rows.
            text_src = colors.get("accent") or colors.get("color4") or "cyan"
            text_color = self._hover_color(text_src) if dim else text_src
            composed = Text()
            composed.append(
                f"{glyph}  ", style=Style(color=icon_color, bold=True)
            )
            composed.append(
                label.plain, style=Style(color=text_color, bold=True)
            )
            label = composed
        return label

    def _filter_icon_color(self, colors: dict) -> str:
        """Filter-state tint for group folder icons. Osaka Jade — the
        user's primary theme — gets a hand-tuned mint (#86EFAC) that
        looks correct against its specific accent. Every other theme
        gets a "lifted accent": parse the accent, push lightness and
        saturation up in HSL space, return the result. That keeps the
        cue in the same hue family as the rest of the theme so it
        reads as palette-coherent, while staying far enough from the
        accent's actual lightness to be visibly distinct.

        Pure brightness-blends (color.lighten / blend-toward-white)
        wash out saturation and produced too-subtle results in tests;
        bumping S directly keeps the lifted color vivid. The min/max
        clamps keep dark themes from over-shooting white and very
        light themes from inverting into the unsaturated zone."""
        name = (
            getattr(self.app, "_omarchy_theme_name", "") or ""
        ).lower()
        if "osaka" in name and "jade" in name:
            return "#86EFAC"
        import colorsys
        accent_hex = (
            colors.get("accent") or colors.get("color4") or "#509475"
        )
        try:
            accent = Color.parse(accent_hex)
            h, l, s = colorsys.rgb_to_hls(
                accent.r / 255, accent.g / 255, accent.b / 255
            )
            new_l = max(min(l + 0.30, 0.78), 0.70)
            new_s = max(s, 0.60)
            r, g, b = colorsys.hls_to_rgb(h, new_l, new_s)
            return Color(
                int(round(r * 255)),
                int(round(g * 255)),
                int(round(b * 255)),
            ).hex
        except Exception:
            return "#86EFAC"

    def _is_group_filtered(self, node) -> bool:
        """True when `node`'s saved-group is in the workspace's
        filtered set. Reverse-looks up the group name via
        app._saved_nodes (insertion order = render order) and consults
        the cached filtered set refreshed at the start of each
        _rebuild_tree. The pending-new-group placeholder has an empty
        key, which `not group_name` rejects so it never reads as
        filtered while in preview."""
        app = self.app
        saved_nodes = getattr(app, "_saved_nodes", {})
        group_name = next(
            (g for g, n in saved_nodes.items() if n is node),
            "",
        )
        if not group_name:
            return False
        return group_name in getattr(app, "_filtered_groups", set())

    def action_toggle_node(self) -> None:
        # Textual's Tree binds space → toggle_node, which expands or
        # collapses the cursor branch. During inline edit, space is a
        # valid character in the buffer — swallow the toggle so typing
        # a space doesn't collapse the placeholder header (or a nearby
        # group during rename). Same gate for the save-to-existing
        # picker, where nothing visual should change mid-pick.
        # Post-commit window: _suppress_activate_until is set by every
        # _commit_* handler precisely because our on_key commit path
        # clears the edit state *before* Tree's parallel binding fires,
        # so the plain edit-mode check would miss the toggle that fires
        # right after Enter commits. The timestamp check closes that gap.
        app = self.app
        if app._in_any_edit_mode() or app._save_picker_row is not None:
            return
        if time.monotonic() < app._suppress_activate_until:
            return
        super().action_toggle_node()

    def action_select_cursor(self) -> None:
        # Tree's built-in `enter` binding calls this, which on a branch
        # node calls `node.toggle()` AND posts NodeSelected. During
        # group-rename / new-group edit the cursor sits on (or near) a
        # branch, and Enter is meant to commit the edit — not toggle
        # the group's expansion.
        # Two gates in sequence: (1) active edit/picker → noop so Enter
        # stays a pure commit path; (2) post-commit suppression window
        # → noop so the Tree binding that fires *after* on_key's commit
        # (by which point edit state is already cleared) doesn't toggle
        # the freshly-committed group. on_tree_node_selected relies on
        # the same timestamp; reusing it keeps both side-effects of
        # select_cursor (activate + toggle) suppressed in lockstep.
        app = self.app
        if app._in_any_edit_mode() or app._save_picker_row is not None:
            return
        if time.monotonic() < app._suppress_activate_until:
            return
        super().action_select_cursor()

    def _render_edit_label(self, *, prefix, buffer, cursor, cursor_on, colors):
        """Shared label renderer for every inline-edit mode (tab rename,
        group rename, new-group preview). `prefix` is the stable head
        (icon glyph + spacing + optional 'Saved: ' for group flavors);
        `buffer` is the editable text; `cursor` is the 0..len insertion
        index; `cursor_on` drives the block-cursor blink. Returns a Rich
        Text painted in accent color with a terminal-style inverted
        cursor cell. Bypasses the rest of render_label's styling flow
        (hover-dim, active-tab highlight) so edit mode owns the row."""
        accent = colors.get("accent") or "#cccccc"
        bg = colors.get("background") or "#000000"
        cur = max(0, min(cursor, len(buffer)))
        if cur < len(buffer):
            head, cursor_char, tail = buffer[:cur], buffer[cur], buffer[cur + 1:]
        else:
            head, cursor_char, tail = buffer, " ", ""
        # Window the buffer around the cursor so it never scrolls off-
        # screen. Overhead = prefix cell width + a small safety margin so
        # the math adapts to either the tab-row or group-header flavor.
        prefix_cells = len(prefix)
        avail = max(4, (self.size.width or 24) - prefix_cells - 4)
        if len(head) + 1 + len(tail) > avail:
            half = max(1, (avail - 1) // 2)
            if len(head) <= half:
                tail_room = avail - 1 - len(head)
                if len(tail) > tail_room:
                    tail = (tail[:max(0, tail_room - 1)] + "…") if tail_room > 0 else ""
            elif len(tail) <= half:
                head_room = avail - 1 - len(tail)
                if len(head) > head_room:
                    head = "…" + head[-(max(0, head_room - 1)):] if head_room > 0 else ""
            else:
                head_room = half
                tail_room = avail - 1 - head_room
                head = "…" + head[-(head_room - 1):] if head_room > 1 else "…"
                tail = tail[:tail_room - 1] + "…" if tail_room > 1 else "…"
        label = Text()
        label.append(prefix, style=Style(color=accent, bold=True))
        label.append(head, style=Style(color=accent))
        if cursor_on:
            label.append(cursor_char, style=Style(color=bg, bgcolor=accent))
        else:
            label.append(cursor_char, style=Style(color=accent))
        label.append(tail, style=Style(color=accent))
        return label

    ICON_NODE = ""           # rendered inline in render_label
    ICON_NODE_EXPANDED = ""  # rendered inline in render_label
    _FOLDER_CLOSED = "\uf07b"  # nf-fa-folder
    _FOLDER_OPEN = "\uf07c"    # nf-fa-folder-open
    # "filtered" group state reuses the open-folder glyph but tints it
    # with the theme's bright-green slot (color10) — same hue family
    # as the accent, just lighter, so it reads as a related-but-
    # distinct state. Separate glyphs from different icon families
    # came out at different cell widths and looked visually mismatched
    # which is why this is a tint, not a different glyph. Resolved at
    # render time by FolderTree._filter_icon_color so it survives
    # themes that flatten color10 onto the accent.


def _glyph(url: str) -> str:
    # Phase 1: render-path stays pure — no network calls. Kitty-graphics
    # rendering (which needs a cached PNG) lands in phase 2 with a background
    # fetch worker — see docs/bm-tool-PLAN.md.
    return favicon.FALLBACK_GLYPH


def _loose_url_key(url: str) -> str:
    """Pair-fallback key: scheme + host + path, ignoring query and
    fragment. Used by `_rebuild_tree`'s second pairing pass to match
    saved↔live when the saved URL captured a volatile query param
    (Google's `?zx=<nonce>`, jquery cache-busters, redirect-tracking
    `gclid`/`fbclid`, etc.) and the live tab no longer carries the
    same one. Falls back to the raw URL on any parse error so the
    pairing pass stays resilient to malformed URLs in saved-tabs.json."""
    try:
        p = urlsplit(url)
        return f"{p.scheme}://{p.netloc}{p.path}"
    except Exception:
        return url


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
        Binding("t", "new_tab", "new tab"),
        Binding("s", "save_selected", "save"),
        Binding("S", "save_new_group", "save to new group", show=False),
        Binding("e", "edit_url", "edit url", show=False),
        Binding("d", "delete_saved", "delete"),
        Binding("u", "unload_tab", "unload tab", show=False),
        Binding("r", "rename_saved", "rename"),
        Binding("R", "reload_saved", "reload tab", show=False),
        Binding("y", "yank_url", "yank url", show=False),
        Binding("Y", "yank_saved_url", "yank saved url", show=False),
        Binding("m", "enter_move_mode", "move", show=False),
        Binding("w", "switch_workspace", "switch workspace", show=False),
        Binding("W", "new_workspace", "new workspace", show=False),
        Binding("semicolon", "cycle_workspace", "next workspace", show=False),
        Binding("slash", "focus_search", "/"),
        Binding("p", "peek", "peek", show=False),
        Binding("P", "toggle_preview", "preview", show=False),
        Binding("question_mark", "show_help", "help", show=False),
        Binding("escape", "quit_to_browser", "browser"),
        Binding("q", "quit", "quit"),
    ]

    filter_text: reactive[str] = reactive("")

    def __init__(self) -> None:
        super().__init__()
        self._live: list[cdp.Tab] = []
        self._saved: list[store.SavedTab] = []
        # Workspaces: array order = display order in the switcher; the
        # first one is the fallback when state.currentWorkspace points at
        # a deleted id. Reloaded alongside _saved every _load_all call so
        # in-flight CRUD via the CLI shows up immediately.
        self._workspaces: list[store.Workspace] = []
        # Current workspace id (uuid hex). Empty until on_mount has
        # resolved it from state.json or workspaces[0]. Saved tabs and
        # loose live leaves are filtered to this workspace at render
        # time; Essentials are global.
        self._current_workspace: str = ""
        # Per-chromium-tab workspace tag — stamped at the tab's first
        # observation and never changes for the life of the tab. Loose
        # live leaves are filtered by `_tab_workspace[tab.id] ==
        # _current_workspace`. Persisted to state.openTabUrlsByWorkspace
        # by URL each refresh tick so chromium session-restore can
        # re-derive tags on the next bm boot.
        self._tab_workspace: dict[str, str] = {}
        # First-time-seed gate for URL-based tag reconstruction. The
        # initial _load_all reads state.openTabUrlsByWorkspace and
        # matches the chromium-restored tabs by URL; subsequent passes
        # default new tabs to the current workspace. Mirrors the role of
        # _initial_pair_done for saved↔live pairing.
        self._tab_tags_seeded: bool = False
        # Active picker state for the workspace switcher (`w`). None
        # when closed; an int index when the picker is open.
        self._workspace_picker_index: Optional[int] = None
        # Cached workspace list shown by the active switcher — captured
        # at picker open so list changes mid-picker don't shift the
        # cursor under the user.
        self._workspace_picker_items: list[store.Workspace] = []
        # New-workspace preview-before-commit (`W`). True while the
        # placeholder Workspace label is in inline edit mode.
        self._pending_new_workspace: bool = False
        # Destructive-action confirm prompt (`d`) state. None when no
        # prompt is pending; a dict `{"kind": ..., "target_id": ...,
        # "label": ...}` while the y/N modal owns the bottom bar.
        self._pending_confirm: Optional[dict] = None
        self._saved_nodes: dict[str, TreeNode] = {}
        # Mutable per-instance state — declared here (not as class attrs)
        # so multiple BmApp instances wouldn't share a dict/list. The
        # immutable counterparts (_save_picker_index, _last_save_group,
        # etc.) stay as class attrs to keep the type-annotation block
        # readable.
        self._save_picker_groups: list[str] = []
        self._live_titles: dict[str, str] = {}
        # Session pairing: maps a saved tab's stable id (SavedTab.id —
        # uuid hex from saved-tabs.json) to the chromium tab_id it was
        # activated into during this bm session. Populated by
        # _open_saved / _peek_row when a saved row is activated,
        # consulted by the pairing pass in _rebuild_tree as the highest-
        # priority match so the saved row stays paired with that tab
        # even after the user navigates within it (clicks a link,
        # follows a redirect, etc.). Keyed on id rather than URL so
        # duplicate URLs across rows each get their own pair, and so
        # URL edits / group moves don't need to migrate dict keys —
        # the id is stable across both. Stale entries (tab_id gone or
        # saved id removed) are reaped during the pairing pass.
        # Reopening a saved row whose session tab is closed creates a
        # new chromium tab from the saved URL — the desired "session
        # restart" behaviour.
        self._saved_session_tab_id: dict[str, str] = {}
        # First-rebuild gate. URL-based auto-pairing (the exact and
        # loose passes below) is convenient on startup — saved rows
        # show paired with already-open chromium tabs without any user
        # action — but after bm is running, it's surprising: a loose
        # tab that the user happens to navigate to a saved URL would
        # silently get swallowed by the saved row instead of staying
        # in "Open Tabs". Once the first rebuild has run, only session
        # pairing (populated by explicit Enter / o / save flows) keeps
        # tabs paired. Save commit paths claim the session manually so
        # newly-saved rows pair instantly without depending on this
        # gate.
        self._initial_pair_done: bool = False
        # Per-workspace cursor memory. Each entry maps a workspace_id
        # to the cursor's row identity (url + kind + saved_id +
        # tab_id) at the moment the user last left that workspace.
        # On re-entry, _rebuild_tree consults this slot via
        # _pending_workspace_cursor to land the cursor back on the
        # same row instead of inheriting the outgoing workspace's
        # cursor position (which would either fail to match in the
        # incoming tree, dropping the cursor to the Workspace title,
        # or coincidentally match — typically an Essentials row —
        # parking the cursor somewhere the user wasn't expecting).
        self._workspace_cursors: dict[str, dict] = {}
        # Set by workspace switch / cycle / new-workspace paths just
        # before they call _rebuild_tree, so the rebuild's cursor
        # capture uses the *incoming* workspace's saved snapshot
        # instead of the live tree (which still reflects the outgoing
        # workspace at capture time). Consumed and cleared inside the
        # rebuild.
        self._pending_workspace_cursor: dict | None = None
        # Per-workspace remembered active tab. Maps workspace_id →
        # chromium tab_id of the row that was last "active" (yellow
        # highlight) in that workspace. Used so that when the user
        # switches workspaces, the highlight in the new workspace
        # reflects what was active there last time, instead of
        # blanking out (because the global `_active_tab_id` still
        # points at chromium's currently-focused tab, which may live
        # in a different workspace). Updated on every chromium-focus
        # observation that lands in the current workspace, on every
        # bm-driven activation (`_mark_active`), and reset on manual
        # workspace switch via `_restore_workspace_active`. Stale
        # entries (tab closed) are reaped by `_sync_tab_workspace_tags`.
        self._workspace_active_tab: dict[str, str] = {}
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
        # Current omarchy theme name (e.g. "osaka-jade"). Cached so the
        # filtered-folder color resolver can apply per-theme overrides
        # without re-reading the marker file every render frame.
        self._omarchy_theme_name: str = bm_theme.load_name()

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
            # SIGRTMIN — `bm workspace next` (Super+Alt+;) cycle to the
            # next workspace. Same in-process action as the `;` keybind,
            # so the external trigger walks the same path the user sees
            # in bm. _cycle_workspace_step is a no-op when bm has fewer
            # than two workspaces, so the binding is harmless when a
            # single workspace exists.
            loop.add_signal_handler(
                signal.SIGRTMIN, self._cycle_workspace_step
            )
        except (NotImplementedError, RuntimeError):
            pass
        # om37: watch hyprland's IPC event socket for our window's
        # closewindow event. On hyprland 0.54+ / ghostty 1.3+, Super+W
        # destroys the GTK surface but ghostty does NOT reliably exit
        # the process, so the PTY stays alive and bm-py never receives
        # SIGHUP — the original "Super+W -> ghostty exits -> SIGHUP ->
        # _cleanup() -> close_chromium" chain breaks at hop #1, leaving
        # chromium open. Listening directly to hyprland sidesteps the
        # broken intermediary.
        # Stash the task on self: asyncio holds only weak refs to tasks
        # (see https://docs.python.org/3/library/asyncio-task.html#asyncio.create_task),
        # so a bare `asyncio.create_task(...)` can be GC'd before it
        # runs. Verified empirically — without this attribute, bm-py
        # never opened a connection to .socket2.sock.
        try:
            self._close_watcher_task = asyncio.create_task(
                self._watch_hyprland_close()
            )
        except RuntimeError:
            self._close_watcher_task = None
        # Async chromium-ready driver. The bash launcher only spawns
        # chromium and exec's bm-py — no synchronous wait_for_cdp /
        # clean_tabs blocking before the TUI starts. We pick up that
        # work here on the asyncio loop so bm-py's UI paints
        # immediately, with live-tab indicators populating once CDP is
        # ready (~1s on cold start). Same weak-ref GC caveat as the
        # close watcher applies — stash on self.
        try:
            self._chromium_ready_task = asyncio.create_task(
                self._wait_for_chromium_ready()
            )
        except RuntimeError:
            self._chromium_ready_task = None
        self.set_interval(REFRESH_SECONDS, self._refresh_live)
        self.set_interval(0.5, self._blink_cursor)
        tree = self.query_one("#tree", FolderTree)
        tree.focus()
        # Park the cursor on first paint so the hover-dim doesn't land
        # on the Workspace row before the user has actually navigated.
        # Any motion action (j/k, external cycle, etc.) reactivates it
        # via _activate_cursor.
        tree.cursor_active = False

    def _find_own_window_address(self) -> Optional[str]:
        # Resolve our hyprland window address. Prefer pid+class match
        # (exact: ghostty's pid via getppid + bm class). Fall back to
        # class-only because some compositor configurations report a
        # child process's pid for the GTK surface rather than ghostty's
        # own pid. Class-only is safe given the 023-00127 focus fix
        # (one com.ko.bm window per session).
        try:
            result = subprocess.run(
                ["hyprctl", "clients", "-j"],
                capture_output=True, text=True, timeout=1,
            )
            if result.returncode != 0:
                return None
            clients = json.loads(result.stdout)
            target = os.getppid()
            for c in clients:
                if c.get("pid") == target and c.get("class") == "com.ko.bm":
                    addr = c.get("address")
                    if addr:
                        return addr
            for c in clients:
                if c.get("class") == "com.ko.bm":
                    addr = c.get("address")
                    if addr:
                        return addr
        except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
            pass
        return None

    async def _wait_for_chromium_ready(self, timeout: float = 15.0) -> None:
        # Drive chromium-readiness asynchronously after the bash
        # launcher fired `launch_chromium` and exec'd into bm-py
        # without waiting for CDP. Polls cdp.is_up every 0.3s on the
        # event loop (sync httpx calls offloaded to a thread pool so
        # they don't block Textual's render). On success, runs
        # launcher.clean_tabs ONLY when the bash launcher set
        # BM_COLD_LAUNCH=1 — i.e. chromium was just spawned this run
        # and the restored-session tabs need to be replaced with a
        # single about:blank. Warm-start runs preserve whatever the
        # user already had open.
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            try:
                up = await loop.run_in_executor(None, cdp.is_up)
            except Exception:
                up = False
            if up:
                if os.environ.get("BM_COLD_LAUNCH") == "1":
                    try:
                        await loop.run_in_executor(None, launcher.clean_tabs)
                    except Exception:
                        pass
                return
            await asyncio.sleep(0.3)

    async def _watch_hyprland_close(self) -> None:
        # Stream hyprland IPC events; on `closewindow>>ADDR` for our
        # own window, kill chromium directly and os._exit. Address
        # comparison strips the 0x prefix that hyprctl reports but
        # the event socket omits.
        his = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if not his or not runtime:
            return
        sock_path = f"{runtime}/hypr/{his}/.socket2.sock"
        # Ghostty/GTK may take a moment to register the window with
        # hyprland after on_mount fires. Poll briefly so we don't bail
        # out before the address exists.
        own_addr: Optional[str] = None
        for _ in range(50):
            own_addr = self._find_own_window_address()
            if own_addr:
                break
            await asyncio.sleep(0.1)
        if not own_addr:
            return
        needle = own_addr[2:] if own_addr.startswith("0x") else own_addr
        try:
            reader, writer = await asyncio.open_unix_connection(sock_path)
        except (OSError, FileNotFoundError):
            return
        try:
            while True:
                line = await reader.readline()
                if not line:
                    return
                text = line.decode("utf-8", errors="ignore").strip()
                if not text.startswith("closewindow>>"):
                    continue
                if text.split(">>", 1)[1] != needle:
                    continue
                _fast_close_and_exit()
        except (OSError, ConnectionError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    def _blink_cursor(self) -> None:
        # Expire status messages whose timeout has elapsed.
        if self._status_message and time.monotonic() >= self._status_clear_at:
            self._status_message = ""
            self._update_search_tree()
        if self._in_search_mode:
            self._cursor_on = not self._cursor_on
            self._update_search_tree()
        elif self._in_any_edit_mode():
            # Inline edit (rename / new-group preview) has its own cursor
            # glyph drawn by render_label; toggle the shared flag and
            # invalidate the tree so the block character blinks in place.
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
        filter owns j/k already. Move mode short-circuits too — j/k
        inside bm are reorder commands, so the matching external
        cycle keybinds shouldn't drive a different action; the user
        cancels MOVE manually."""
        if self._in_help_mode or self._in_search_mode:
            return
        if self._in_move_mode:
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

    def _open_confirm(
        self, kind: str, target_id: str, label: str
    ) -> None:
        """Open the destructive-action confirm prompt. `kind` is one of
        delete_workspace / delete_group / delete_saved / delete_essential
        / close_live; `target_id` is the workspace id, group name, saved
        id, or chromium tab id depending on kind. `label` is the rendered
        prompt text (e.g. `Delete workspace?`).
        """
        self._pending_confirm = {
            "kind": kind,
            "target_id": target_id,
            "label": label,
        }
        self._update_search_tree()

    def _commit_confirm(self) -> None:
        """Dispatch the pending destructive action. Cleared first so a
        rebuild during the action doesn't see modal state."""
        pending = self._pending_confirm
        if pending is None:
            return
        self._pending_confirm = None
        kind = pending["kind"]
        target = pending["target_id"]
        if kind == "delete_workspace":
            self._do_delete_workspace(target)
        elif kind == "delete_group":
            self._do_delete_group(target)
        elif kind in ("delete_saved", "delete_essential"):
            self._do_delete_saved(target, kind)
        elif kind == "close_live":
            self._do_close_live(target)
        self._update_search_tree()

    # --- destructive-action handlers (committed via _commit_confirm) ---

    def _do_delete_workspace(self, workspace_id: str) -> None:
        if not workspace_id:
            return
        # store.remove_workspace refuses on the only remaining
        # workspace; report that as a status so the user knows why the
        # press was a no-op.
        if not store.remove_workspace(workspace_id):
            self._set_status("Cannot delete the only workspace")
            return
        was_current = workspace_id == self._current_workspace
        # Reload workspace + tab list to reflect the delete.
        self._workspaces = store.load_workspaces()
        self._saved = store.load_saved()
        # Drop tag entries for any chromium tabs that were associated
        # with the deleted workspace — they become "orphans" and
        # default to current on the next refresh tick. The on-disk URL
        # list for the deleted workspace is rewritten by the refresh
        # via _persist_open_tab_urls (the deleted id is omitted from
        # the new map by virtue of not appearing in self._workspaces).
        for tab_id, ws in list(self._tab_workspace.items()):
            if ws == workspace_id:
                del self._tab_workspace[tab_id]
        # The deleted workspace can never be re-entered, so its
        # cursor memory + remembered active are dead weight — drop
        # the slots regardless of whether it was current.
        self._workspace_cursors.pop(workspace_id, None)
        self._workspace_active_tab.pop(workspace_id, None)
        if was_current:
            # Switch into the new top-of-array workspace.
            self._current_workspace = (
                self._workspaces[0].id if self._workspaces else ""
            )
            store.set_current_workspace(self._current_workspace)
            self._pending_workspace_cursor = (
                self._workspace_cursors.get(self._current_workspace) or {}
            )
            self._restore_workspace_active(self._current_workspace)
            # Re-arm URL-pair seeding for the incoming workspace's
            # saved rows — they were filtered out at startup so the
            # seed pass never ran for them. The session map itself is
            # left intact: it's keyed on saved_id (unique across
            # workspaces), and the rebuild's reaper drops any entry
            # whose saved row was deleted with the workspace, so
            # pairings for surviving workspaces survive the switch.
            self._initial_pair_done = False
        # Persist the rebuilt URL map (deleted workspace's slot is
        # naturally absent from the new self._workspaces).
        self._persist_open_tab_urls()
        self._set_status("Deleted Workspace")
        self._rebuild_tree()

    def _do_delete_group(self, group_name: str) -> None:
        if not group_name:
            return
        # Group rename is blocked on Essentials, but `d` on the
        # Essentials top-level leaves goes through delete_essential,
        # not delete_group — group_name is always a real user group
        # here.
        removed = store.remove_group(group_name, self._current_workspace)
        if removed == 0:
            return
        self._saved = store.load_saved()
        # Drop any session pairings for saved rows that no longer
        # exist so a subsequent rebuild's reaper doesn't have to.
        saved_ids = {t.id for t in self._saved}
        for sid in list(self._saved_session_tab_id.keys()):
            if sid not in saved_ids:
                del self._saved_session_tab_id[sid]
        self._set_status("Deleted Group")
        self._rebuild_tree()

    def _do_delete_saved(self, saved_id: str, kind: str) -> None:
        if not saved_id:
            return
        # Find the saved row first so we can close its paired live tab
        # if any. The kind tells us whether to render "Saved Tab" or
        # "Essential" in the status.
        target = next((t for t in self._saved if t.id == saved_id), None)
        if target is None:
            return
        paired_tab_id = self._saved_session_tab_id.get(saved_id, "")
        if paired_tab_id:
            try:
                cdp.close_tab(paired_tab_id)
            except Exception:
                pass
            self._saved_session_tab_id.pop(saved_id, None)
        if not store.remove_saved(saved_id):
            return
        self._saved = store.load_saved()
        # Force an immediate refresh so the closed tab drops out of
        # self._live before the next rebuild and the row vanishes
        # without a 300ms wait.
        self._refresh_live()
        label = "Deleted Essential" if kind == "delete_essential" else "Deleted Saved Tab"
        self._set_status(label)
        self._rebuild_tree()

    def _do_close_live(self, tab_id: str) -> None:
        if not tab_id:
            return
        try:
            cdp.close_tab(tab_id)
        except Exception:
            pass
        # Drop the workspace tag — _refresh_live's incremental sync
        # would do this on the next tick anyway, but explicit removal
        # avoids briefly flashing a stale entry through state.json.
        self._tab_workspace.pop(tab_id, None)
        self._refresh_live()
        self._set_status("Deleted Open Tab")
        self._rebuild_tree()

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
        if self._pending_confirm is not None:
            # Destructive-action confirm prompt — single row owns the
            # primary slot. Suffix-shaped (y/N) hint is rendered
            # alongside (right-aligned, dim tier) below in the suffix
            # branch so the existing alignment math handles it.
            primary = Text(self._pending_confirm.get("label", "Delete?"))
        elif self._workspace_picker_index is not None:
            # Workspace switcher — same two-line shape as the save
            # picker, but the primary row shows the *currently
            # highlighted* workspace name. Header is rendered below in
            # the picker_header branch.
            items = self._workspace_picker_items
            if items:
                idx = max(0, min(self._workspace_picker_index, len(items) - 1))
                primary = Text(items[idx].name)
            else:
                primary = Text("")
        elif self._save_picker_row is not None:
            # Save-to-existing-group picker. Two-line bar — header row
            # ('Save to:' + right-aligned '(↑/↓)' hint) is added below
            # via the picker_header branch; primary is just the current
            # group name so it gets the full status row to itself.
            # ↑/↓ cycle, Enter commits, Esc cancels (handled in on_key).
            # Takes priority over search/status/filter so the picker
            # owns the bottom bar exclusively while open.
            current = (
                self._save_picker_groups[self._save_picker_index]
                if self._save_picker_groups else ""
            )
            # Essentials renders with brackets so it reads as the
            # special bucket pinned at the bottom of the list, distinct
            # from regular folder groups above it. The underlying
            # picker value stays plain `Essentials` for the store call.
            display = (
                f"[{current}]" if current == ESSENTIALS_GROUP else current
            )
            primary = Text(display)
        elif self._in_search_mode:
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
        # Suffix priority: rename > group-rename > new-group > preview.
        # All suppressed during search typing, status messages, and the
        # save picker (the picker owns the entire bar). Rename modes are
        # all dimmer-tier markers so they read as the same indicator class.
        marker_blocked = (
            self._in_search_mode
            or bool(self._status_message)
            or self._save_picker_row is not None
            or self._workspace_picker_index is not None
        )
        if self._pending_confirm is not None:
            # `(y/N)` rides in the right-aligned suffix slot, same dim
            # tier as the [preview] marker family. No marker_blocked
            # gate — the prompt actively wants the hint visible.
            suffix = Text("(y/N)", style=preview_faded)
        elif self._rename_url is not None and not marker_blocked:
            suffix = Text("[rename]", style=preview_faded)
        elif self._rename_group is not None and not marker_blocked:
            suffix = Text("[rename]", style=preview_faded)
        elif self._rename_workspace_id is not None and not marker_blocked:
            suffix = Text("[rename]", style=preview_faded)
        elif self._pending_new_workspace and not marker_blocked:
            suffix = Text("[new workspace]", style=preview_faded)
        elif self._url_edit_url is not None and not marker_blocked:
            suffix = Text("[edit url]", style=preview_faded)
        elif self._pending_new_group_row is not None and not marker_blocked:
            suffix = Text("[new group]", style=preview_faded)
        elif self._in_move_mode and not marker_blocked:
            suffix = Text("[move]", style=preview_faded)
        elif self._in_preview_mode and not marker_blocked:
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
        # In picker mode, prepend a header row above `primary` so the bar
        # reads as 'Save to:    (↑/↓)' / '<group name>'. Bumps the
        # widget to height:2 while open and reverts to 1 otherwise.
        # Same right-align trick as the [preview] suffix above; size.width
        # is 0 on the first lay-out pass, so we fall back to a fixed gap
        # and reschedule once layout settles.
        if (
            self._save_picker_row is not None
            or self._workspace_picker_index is not None
        ):
            header = Text("⠀")
            header_text = (
                "Switch to:"
                if self._workspace_picker_index is not None
                else "Save to:"
            )
            header.append(Text(header_text, style=preview_faded))
            hint = Text("(↑/↓)", style=preview_faded)
            width = search_tree.size.width
            used = header.cell_len + hint.cell_len
            if width == 0:
                gap = 2
                self.call_after_refresh(self._update_search_tree)
            else:
                gap = max(2, width - used - 1)
            header.append("⠀" * gap)
            header.append(hint)
            search_tree.styles.height = 2
            search_tree.root.add_leaf(header, data=_SearchMarker())
        else:
            search_tree.styles.height = 1
        search_tree.root.add_leaf(label, data=_SearchMarker())

    def on_app_blur(self, event) -> None:
        """Auto-exit MOVE mode when bm loses window focus. Two reasons:
        the persistent [move] indicator can't be seen from outside bm,
        and external signal handlers (Super+Alt+J/K/;) gate on
        _in_move_mode and silently no-op while it's set — so leaving
        bm in MOVE mode would make those keybinds appear broken until
        the user came back and Esc'd. Auto-exit here closes the loop:
        focus leaves → mode clears → next external keybind works."""
        if self._in_move_mode:
            self._exit_move_mode()

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
    # Disambiguators for the rename target when a row's URL alone isn't
    # unique. Saved-tabs.json now allows duplicate URLs anywhere (same
    # URL across groups *and* within a single group), so URL is no
    # longer a unique key among saved rows either. Resolution:
    #   - saved-row rename → match on SavedTab.id (`_rename_saved_id`),
    #     stable across rename / move / URL edit.
    #   - live-row rename → match on chromium tab_id (`_rename_tab_id`),
    #     unique per tab so multiple tabs sharing a URL each get their
    #     own override.
    # `_rename_kind` picks which key to use. render_label,
    # _commit_rename_url, and _restore_edit_cursor all consult these
    # together. `_rename_url` is still kept around as the "is rename
    # mode active" sentinel + the value seeding the buffer/display, but
    # it's never used as a lookup key on its own anymore.
    _rename_kind: Optional[str] = None  # "saved" or "live"
    _rename_tab_id: Optional[str] = None  # chromium tab id, live rows only
    _rename_saved_id: Optional[str] = None  # SavedTab.id, saved rows only
    _rename_buffer: str = ""
    _rename_cursor: int = 0
    # Group rename target — set when `r` is pressed on a Saved: header.
    # Distinct from _rename_url so the buffer/cursor machinery is shared
    # but render_label and the commit path know which kind of edit is in
    # flight. Mutually exclusive with _rename_url and _pending_new_group.
    _rename_group: Optional[str] = None
    # URL edit target — set when `e` is pressed on a saved row. Holds
    # the row's *original* URL so render_label can seed the buffer for
    # display fallbacks; the new URL lives in the shared rename buffer.
    # `_url_edit_saved_id` is the actual lookup key for the commit (and
    # render_label match), since URL alone is no longer unique among
    # saved rows. Distinct from _rename_url so render_label and commit
    # dispatch know to update the URL field, not the title.
    _url_edit_url: Optional[str] = None
    _url_edit_saved_id: Optional[str] = None
    # Workspace rename target — set when `r` is pressed on the
    # Workspace row. Holds the workspace id so the commit path can
    # call store.rename_workspace(id, new_name). Mutually exclusive
    # with the other edit modes.
    _rename_workspace_id: Optional[str] = None
    # Save-to-existing-group picker state. While _save_picker_row is set,
    # the bottom bar shows '→ Save to: <group>' and ↑/↓ cycle through
    # _save_picker_groups, with _save_picker_index indexing the selection.
    # Enter commits via store.add_saved(group=current); Esc cancels.
    _save_picker_row: Optional["Row"] = None
    _save_picker_groups: list[str] = []
    _save_picker_index: int = 0
    # Remembers the last group the user saved into so `s` defaults to it
    # next time. Falls back to the first group when this name no longer
    # exists. Empty string on first launch.
    _last_save_group: str = ""
    # Save-to-new-group preview state. While _pending_new_group_row is
    # set, the tree renders a placeholder 'Saved: <buffer>' header with
    # the tab leaf beneath it (no persisted data). The header is in
    # inline edit mode reusing _rename_buffer/_rename_cursor; Enter
    # commits via store.add_saved with the typed name as the group; Esc
    # rolls everything back. Mutually exclusive with the rename modes —
    # at most one edit-buffer state is ever active.
    _pending_new_group_row: Optional["Row"] = None
    # Session-only live-tab title overrides, keyed by chromium tab_id.
    # Populated by `r` on a live row; consulted in _format_row and
    # render_label. Cleared by _stable_sort_live when a tab id no longer
    # exists. Never persisted.
    _live_titles: dict[str, str] = {}
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
    # Tab id we just told chromium to focus via a workspace-switch
    # activation, used by _refresh_live to gate the cross-workspace
    # follow until chromium's MRU catches up. cdp.activate is sync,
    # but chromium's /json/list MRU update can briefly lag the
    # /json/activate ack — when that lag straddles a refresh tick,
    # `chromium_focused.id` still reads as the OUTGOING workspace's
    # tab even though we just instructed chromium to switch. Without
    # this gate, the refresh tick would fire active_changed, see the
    # lingering pre-switch tab, and flip current_workspace back to
    # the workspace we just left — visible as a flash on the active-
    # tab highlight as the next tick (with chromium caught up) flips
    # forward again. Cleared once chromium_focused matches.
    _pending_workspace_active_tab_id: str = ""
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
    # Snapshot of the current workspace's filtered-group set, refreshed
    # at the start of every _rebuild_tree. FolderTree.render_label
    # reads this to pick the filter-funnel glyph for filtered groups
    # — without the cache it'd re-read state.json on every paint.
    _filtered_groups: set = set()
    # Move/reorder mode. Entered by `m`; while True, j/k swap the
    # carried row/group with its neighbor in scope (rows in same group,
    # essentials with essentials, group headers with group headers,
    # loose live tabs with loose live tabs). Exited by m or escape.
    # Plumbed into _in_modal_state so non-movement actions bail; j/k
    # explicitly bypass that gate to perform the swap.
    _in_move_mode: bool = False

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
        # Load workspaces alongside saved tabs — schema v2 keeps both
        # in saved-tabs.json. Falls back to mint-on-first-read when the
        # file is absent or pre-v2 (handled inside store.load_all).
        self._workspaces, self._saved = store.load_all()
        # Resolve the current workspace. State-on-disk wins; if it
        # points at a deleted id (or no state has been written yet),
        # fall back to workspaces[0]. Persist the resolution back so
        # the next launch starts coherent regardless of which way the
        # fallback landed.
        if not self._current_workspace:
            persisted = store.get_current_workspace()
            valid_ids = {w.id for w in self._workspaces}
            if persisted and persisted in valid_ids:
                self._current_workspace = persisted
            elif self._workspaces:
                self._current_workspace = self._workspaces[0].id
                store.set_current_workspace(self._current_workspace)
        try:
            live = cdp.list_tabs() if cdp.is_up() else []
        except Exception:
            live = []
        self._live = self._stable_sort_live(live)
        # First-load tag seeding: match chromium-restored tabs to their
        # last-known workspace via URL lookup in
        # state.openTabUrlsByWorkspace. Tabs without a match default to
        # the current workspace. After this pass, subsequent live-tab
        # changes are handled incrementally by _sync_tab_workspace_tags.
        if not self._tab_tags_seeded:
            self._seed_tab_workspace_tags()
            self._tab_tags_seeded = True
        else:
            self._sync_tab_workspace_tags()
        self._rebuild_tree()

    def _workspace_for_tab(self, tab_id: str) -> str:
        """Return the workspace where `tab_id` is currently visible.

        Used by the chromium-focus follow path to decide whether a
        manual tab switch inside chromium should also flip bm to a
        different workspace. Three cases:

        - **Paired with an Essentials saved row** → returns the
          *current* workspace. Essentials render globally, so the
          active tab is already on screen wherever the user is — no
          switch needed.
        - **Paired with a non-Essentials saved row** → returns that
          saved row's workspace id. The saved row only renders inside
          its own workspace, so the user has to be there to see the
          highlight.
        - **Loose / orphan tab** → returns the workspace tag
          (`_tab_workspace[tab_id]`), or current if the tag is missing
          / no longer maps to a live workspace.
        """
        current = self._current_workspace
        if not tab_id:
            return current
        saved_id = next(
            (sid for sid, tid in self._saved_session_tab_id.items()
             if tid == tab_id),
            "",
        )
        if saved_id:
            for s in self._saved:
                if s.id == saved_id:
                    if s.group == ESSENTIALS_GROUP:
                        return current
                    if s.workspace:
                        valid = {w.id for w in self._workspaces}
                        if s.workspace in valid:
                            return s.workspace
                    break
        target = self._tab_workspace.get(tab_id, current)
        valid = {w.id for w in self._workspaces}
        if target not in valid:
            return current
        return target

    def _seed_tab_workspace_tags(self) -> None:
        """One-shot: rebuild `_tab_workspace` from
        state.openTabUrlsByWorkspace by matching each currently-live
        chromium tab's URL against the persisted per-workspace URL
        lists. Falls back to current workspace for tabs that don't
        match any known URL."""
        state = store.load_state()
        by_ws = state.get("openTabUrlsByWorkspace") or {}
        # Build a URL → workspace_id index. First-match wins for
        # duplicate URLs across workspaces; iteration order follows the
        # workspaces[] array so the user-visible "first workspace
        # listed" is the tiebreaker.
        url_to_ws: dict[str, str] = {}
        for w in self._workspaces:
            for url in by_ws.get(w.id, []) or []:
                url_to_ws.setdefault(url, w.id)
        valid_ws_ids = {w.id for w in self._workspaces}
        self._tab_workspace = {}
        for t in self._live:
            ws_id = url_to_ws.get(t.url, "")
            if ws_id not in valid_ws_ids:
                ws_id = self._current_workspace
            self._tab_workspace[t.id] = ws_id
        self._persist_open_tab_urls()

    def _sync_tab_workspace_tags(self) -> None:
        """Incremental: tag any newly-observed live tab ids with the
        current workspace, drop entries for tabs that have closed.
        Called after the first seed pass on every refresh tick that
        sees added/removed ids."""
        live_ids = {t.id for t in self._live}
        # Drop tags for tabs that are gone.
        stale = [tid for tid in self._tab_workspace if tid not in live_ids]
        for tid in stale:
            del self._tab_workspace[tid]
        # Drop remembered-active entries pointing at closed tabs so
        # the next workspace switch back doesn't try to highlight a
        # tab that no longer exists.
        for ws_id in list(self._workspace_active_tab.keys()):
            if self._workspace_active_tab[ws_id] not in live_ids:
                del self._workspace_active_tab[ws_id]
        # Tag freshly-seen tabs with the current workspace. A tab can
        # only enter this branch as a "new" id; once tagged it never
        # changes workspace (URL navigation, save/unsave, pair/unpair
        # don't retag — the tag follows the tab id, not its content).
        for t in self._live:
            if t.id not in self._tab_workspace:
                self._tab_workspace[t.id] = self._current_workspace
        self._persist_open_tab_urls()

    def _persist_open_tab_urls(self) -> None:
        """Rebuild state.openTabUrlsByWorkspace from the current
        _tab_workspace map + live URLs and persist. Called after every
        tag change so a crash mid-session doesn't lose the assignment.
        Cheap — one JSON write per change."""
        url_by_id = {t.id: t.url for t in self._live}
        by_ws: dict[str, list[str]] = {w.id: [] for w in self._workspaces}
        for tab_id, ws_id in self._tab_workspace.items():
            url = url_by_id.get(tab_id)
            if not url:
                continue
            by_ws.setdefault(ws_id, []).append(url)
        try:
            store.set_open_tab_urls_map(by_ws)
        except OSError:
            pass

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
                    and not self._in_modal_state()
                ):
                    raw_tabs = cdp.list_tabs()
                    # Identify chromium's actually-visible tab via the
                    # W3C Page Visibility API rather than /json/list's
                    # array order. /json/list looks MRU-ordered but
                    # background-opened tabs (right-click → Open in
                    # new tab, middle-click) sit at position 0
                    # indefinitely until the user manually clicks them
                    # — picking position 0 stole the active highlight
                    # whenever a link was opened in the background.
                    # cdp.visible_tab probes _active_tab_id first so
                    # the steady-state cost is one WS round-trip;
                    # falls through and returns None when no tab
                    # reports visible (chromium minimized/occluded),
                    # which leaves the prior active highlight in
                    # place. Used to follow manual tab switches inside
                    # chromium (clicking a tab, Ctrl+Tab, etc.) — bm
                    # doesn't observe those events directly, so the
                    # per-tick probe is how the "you are here"
                    # highlight tracks the browser's actual focus, not
                    # just the last tab bm itself activated.
                    chromium_focused = cdp.visible_tab(
                        raw_tabs, prefer_id=self._active_tab_id
                    )
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
                    # Capture the prior active tab id BEFORE the
                    # active_changed branch updates it — the cross-
                    # workspace follow path needs to know whether
                    # this is the very first observation of chromium
                    # focus (boot tick) so it can skip the auto-
                    # switch and let bm respect the user's last-
                    # viewed workspace from state.json.
                    prior_active_tab_id = self._active_tab_id
                    active_changed = (
                        chromium_focused is not None
                        and chromium_focused.id != self._active_tab_id
                    )
                    # Suppress active_changed when chromium hasn't yet
                    # caught up to a proactive workspace-switch
                    # activation. cdp.activate is sync but chromium's
                    # /json/list MRU update can briefly lag, and a
                    # refresh tick caught in that window would see the
                    # outgoing workspace's tab as "focused" and trigger
                    # the cross-workspace flip-back. Holding this gate
                    # until chromium's MRU agrees with what we asked
                    # for keeps the next-tick view stable on the new
                    # workspace.
                    if self._pending_workspace_active_tab_id:
                        pending_alive = any(
                            t.id == self._pending_workspace_active_tab_id
                            for t in raw_tabs
                        )
                        if (
                            chromium_focused is not None
                            and chromium_focused.id == self._pending_workspace_active_tab_id
                        ) or not pending_alive:
                            # Caught up, or the target tab vanished
                            # before chromium could focus it (closed
                            # externally) — either way, drop the gate.
                            self._pending_workspace_active_tab_id = ""
                        else:
                            active_changed = False
                    self._live = new_live
                    if active_changed:
                        self._active_url = chromium_focused.url
                        self._active_tab_id = chromium_focused.id
                    if tabs_changed:
                        # Tag any newly-observed tab ids with the
                        # current workspace; reap entries for closed
                        # tabs; rewrite state.openTabUrlsByWorkspace
                        # from the resulting map. Must run before
                        # _rebuild_tree so the loose-leaves filter
                        # sees fresh tags.
                        self._sync_tab_workspace_tags()
                    if tabs_changed or active_changed:
                        # External focus changes — user clicking a tab
                        # in chromium, or a tab close that promoted the
                        # next tab to active — should pull the bm
                        # cursor along so the visual cursor and the
                        # browser's actual focus stay in lockstep
                        # instead of drifting apart. We park the cursor
                        # (cursor_active=False) before the rebuild so
                        # the unavoidable line-0 stop after tree.clear()
                        # doesn't render the hover-dim on Workspace as
                        # a flash; the active-follow callback restores
                        # the prior parked-state once the cursor has
                        # landed on the new active tab. _rebuild_tree's
                        # own prev_url restore runs first via
                        # call_after_refresh; we register ours after so
                        # the active-follow move wins. _restore_cursor
                        # is a no-op when the URL matches no leaf
                        # (e.g. chrome:// internal pages), which leaves
                        # the prev_url restore in place — desired.
                        if active_changed:
                            tree = self.query_one("#tree", FolderTree)
                            was_cursor_active = tree.cursor_active
                            tree.cursor_active = False
                            # If the now-focused tab lives in a
                            # different workspace, follow it across.
                            # The user clicked something in chromium
                            # that bm can only show by switching
                            # views. Save the outgoing workspace's
                            # cursor first so a later switch back
                            # lands them where they were, and seed the
                            # incoming rebuild's pending-cursor slot
                            # with the active tab so the cursor lands
                            # on it instead of the incoming
                            # workspace's last-remembered row. The
                            # session map is preserved (same rationale
                            # as the manual switch paths).
                            target_ws = self._workspace_for_tab(
                                self._active_tab_id
                            )
                            if (
                                prior_active_tab_id
                                and target_ws
                                and target_ws != self._current_workspace
                            ):
                                self._save_workspace_cursor(
                                    self._current_workspace
                                )
                                self._pending_workspace_cursor = {
                                    "url": self._active_url,
                                    "kind": "live",
                                    "saved_id": "",
                                    "tab_id": self._active_tab_id,
                                }
                                self._current_workspace = target_ws
                                store.set_current_workspace(target_ws)
                                self._initial_pair_done = False
                                target_name = next(
                                    (w.name for w in self._workspaces
                                     if w.id == target_ws),
                                    "",
                                )
                                if target_name:
                                    self._set_status(
                                        f"Switched to {target_name}"
                                    )
                            # Remember this tab as the workspace's
                            # last-active so a manual switch back
                            # restores the highlight to it. Runs after
                            # the cross-workspace flip so
                            # current_workspace already matches the
                            # tab's workspace.
                            self._remember_active_for_current_workspace()
                        self._rebuild_tree()
                        if active_changed:
                            follow_tab_id = self._active_tab_id
                            def _follow_active() -> None:
                                # Pass the chromium tab_id so _restore_cursor
                                # matches the exact paired live tab — URL
                                # alone could land on a duplicate.
                                self._restore_cursor(
                                    tree,
                                    self._active_url,
                                    "live",
                                    "",
                                    follow_tab_id,
                                )
                                tree.cursor_active = was_cursor_active
                            self.call_after_refresh(_follow_active)
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
        only *position* is stabilized, keyed by the immutable tab id.

        Also reaps stale entries from `_live_titles` (session-only rename
        overrides) so closed tabs don't leak overrides into reused ids."""
        current_ids = {t.id for t in tabs}
        self._live_order = [tid for tid in self._live_order if tid in current_ids]
        for t in tabs:
            if t.id not in self._live_order:
                self._live_order.append(t.id)
        by_id = {t.id: t for t in tabs}
        stale_titles = [tid for tid in self._live_titles if tid not in current_ids]
        for tid in stale_titles:
            del self._live_titles[tid]
        return [by_id[tid] for tid in self._live_order if tid in by_id]

    def _rebuild_tree(self) -> None:
        tree = self.query_one("#tree", Tree)
        # Suspend dim-flash bookkeeping for the duration of the
        # rebuild + cursor restoration. Textual's base Tree fires
        # watch_cursor_line during its internal _build phase (when
        # cursor_line gets reassigned to cursor_node._line after
        # the line cache rebuild), and our _reevaluate handler
        # would otherwise read stale/transient cursor_node state
        # mid-rebuild. The post-restore re-eval scheduled below is
        # the one observation we want: pre-rebuild anchors → final
        # cursor + active state.
        if isinstance(tree, FolderTree):
            tree._suspend_dim_eval = True
        # Capture the cursor's current row URL (and kind) so we can restore
        # the selection after tree.clear() wipes the cursor back to line 0.
        # Without this, the 3-second live-tab refresh — or any other
        # rebuild — would throw away local j/k navigation and snap the
        # cursor back up to the Workspace row.
        prev_url = ""
        prev_kind = ""
        prev_saved_id = ""
        prev_tab_id = ""
        # Workspace-switch indicator. When set, the rebuild was kicked
        # off by a switch path (manual cycle, picker, new workspace,
        # cross-workspace chromium follow), and we need to reset
        # cursor_line to 0 explicitly: Textual's tree.clear() retains
        # the numeric cursor_line value, so without an active reset
        # the new tree inherits the outgoing workspace's cursor index
        # — which often lands the user mid-tree (e.g. cycling from
        # KO's row 14 to RPC drops the cursor on whatever happens to
        # render on RPC's row 14). The deferred `_restore_cursor`
        # call below fires after the reset, so a workspace with saved
        # cursor memory still moves the cursor to the right row;
        # workspaces with no memory simply land on row 0 (Workspace
        # title) — same as a fresh boot.
        is_workspace_switch = self._pending_workspace_cursor is not None
        if self._pending_workspace_cursor is not None:
            # Workspace switch path — use the incoming workspace's
            # saved cursor snapshot rather than capturing from the
            # live tree (which still shows the outgoing workspace's
            # cursor here). An empty dict signals "switch with no
            # memory for this workspace yet"; in that case prev_url
            # stays "" and the cursor reset above is the only motion.
            snap = self._pending_workspace_cursor
            self._pending_workspace_cursor = None
            prev_url = snap.get("url", "")
            prev_kind = snap.get("kind", "")
            prev_saved_id = snap.get("saved_id", "")
            prev_tab_id = snap.get("tab_id", "")
        else:
            cur_node = tree.cursor_node
            if cur_node is not None and isinstance(cur_node.data, Row):
                prev_url = cur_node.data.url
                prev_kind = cur_node.data.kind
                # Capture the row's stable identity too — duplicate URLs are
                # allowed across groups now, and URL alone would re-seat the
                # cursor on whichever sibling tree-walk hits first.
                prev_saved_id = cur_node.data.id
                prev_tab_id = cur_node.data.tab_id

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
        # Label is the current workspace's name when one's resolved;
        # falls back to the literal "Workspace" only when no workspaces
        # exist (transient state during a v1\u2192v2 migration race).
        workspace_label = Text()
        workspace_label.append("\u2800")
        workspace_label.append(
            self._current_workspace_name() or "Workspace",
            style=workspace_style,
        )
        tree.root.add_leaf(workspace_label, data=_WorkspaceMarker())
        # Breathing room between Workspace and whatever renders below \u2014
        # essentials, the first group header, or a loose live leaf.
        # Rendered unconditionally so the sidebar layout stays stable
        # across tree states (empty \u2192 one group \u2192 essentials + groups).
        # Previously the leading spacer lived inside the essentials
        # block, so clean-slate and group-only states had the Workspace
        # row butting directly against the next row.
        tree.root.add_leaf(Text("\u2800"), data=_SpacerMarker())

        f = self.filter_text.strip().lower()

        # Pair each saved row with the first live tab sharing its URL
        # (walking self._live, which is stable first-seen order). The
        # paired chromium tab_id is stored on the saved Row so
        # render_label can resolve the "you are here" highlight against
        # that specific tab — when three Yahoo tabs are open and one is
        # saved, only the paired one (saved row) OR one of the two
        # unpaired loose leaves lights up, never two at once.
        # Identity is by SavedTab.id, not URL — duplicate URLs are
        # allowed across (and within) groups and each row has its own
        # pairing slot. paired_tab_id_by_saved_id maps id → chromium
        # tab_id and is consulted when constructing Rows below.
        saved_ids = {s.id for s in self._saved}
        paired_tab_id_by_saved_id: dict[str, str] = {}
        consumed_tab_ids: set[str] = set()
        # Session pairing pass — highest priority. When the user has
        # explicitly activated a saved row this session, the saved row
        # claims that chromium tab_id regardless of how the URL changes
        # inside the tab (link clicks, redirects). _saved_session_tab_id
        # is the only state that survives in-tab navigation; everything
        # else below pairs by URL string and would unpair on the first
        # link click. Stale entries (tab still recorded but the actual
        # chromium tab is gone or the saved id was deleted) are reaped
        # here so the map doesn't grow without bound across sessions.
        live_ids = {t.id for t in self._live}
        for s_id in list(self._saved_session_tab_id.keys()):
            tab_id = self._saved_session_tab_id[s_id]
            if s_id not in saved_ids or tab_id not in live_ids:
                del self._saved_session_tab_id[s_id]
                continue
            paired_tab_id_by_saved_id[s_id] = tab_id
            consumed_tab_ids.add(tab_id)
        # Both URL-based passes only run on the first rebuild — see
        # _initial_pair_done's comment above. After bm is running, only
        # explicit user actions (open / peek / save) can establish a
        # pairing.
        if not self._initial_pair_done:
            # Multiple saved rows can share a URL now, so build a FIFO
            # queue per URL and consume one queue entry per matched live
            # tab. Order follows saved-tabs.json order so the first
            # saved row at a given URL gets the first live tab.
            unpaired_by_url: dict[str, list[str]] = {}
            for s in self._saved:
                if s.id in paired_tab_id_by_saved_id:
                    continue
                unpaired_by_url.setdefault(s.url, []).append(s.id)
            for t in self._live:
                if t.id in consumed_tab_ids:
                    continue
                queue = unpaired_by_url.get(t.url)
                if queue:
                    s_id = queue.pop(0)
                    paired_tab_id_by_saved_id[s_id] = t.id
                    consumed_tab_ids.add(t.id)
                    # Auto-claim so subsequent in-tab navigation
                    # doesn't drop the pair we just made.
                    self._saved_session_tab_id[s_id] = t.id
        # Loose-key fallback for saved URLs that didn't pair exactly —
        # handles the common case where the saved URL has volatile
        # query params (e.g. Google's `?zx=<nonce>` cache-buster) but
        # the live tab is the same logical page. Match by scheme + host
        # + path only, ignoring query and fragment. Pair *only* when
        # exactly one unconsumed live tab matches the loose key, so the
        # heuristic never silently picks one of several similar tabs:
        # if the user has three google.com tabs open, none get paired
        # and the saved row stays unpaired (current behavior).
        if not self._initial_pair_done:
            live_by_loose_key: dict[str, list] = {}
            for t in self._live:
                if t.id in consumed_tab_ids:
                    continue
                live_by_loose_key.setdefault(_loose_url_key(t.url), []).append(t)
            for s in self._saved:
                if s.id in paired_tab_id_by_saved_id:
                    continue
                candidates = live_by_loose_key.get(_loose_url_key(s.url), [])
                if len(candidates) == 1:
                    t = candidates[0]
                    paired_tab_id_by_saved_id[s.id] = t.id
                    consumed_tab_ids.add(t.id)
                    # Drop the consumed candidate so a *second* saved row
                    # with the same loose key can't claim the same live tab.
                    live_by_loose_key[_loose_url_key(s.url)] = []
                    self._saved_session_tab_id[s.id] = t.id
        self._initial_pair_done = True

        # Essentials section — top-level cyan leaves rendered above the
        # saved groups (no folder header). Data-driven from saved tabs
        # whose group is ESSENTIALS_GROUP. Pairing with live tabs reuses
        # the paired_tab_id_by_saved_id map so highlight + activation
        # paths work identically to the saved-group rows. Cyan styling is
        # applied in render_label, keyed on row.group. The leading
        # spacer is the unconditional Workspace-below one added right
        # after the Workspace row, so essentials only contributes its
        # trailing spacer (between essentials and groups).
        essentials = [
            t for t in self._saved
            if t.group == ESSENTIALS_GROUP and _match(t.title, t.url, f)
        ]
        if essentials:
            for s in essentials:
                row = Row(
                    kind="saved",
                    title=s.title,
                    url=s.url,
                    group=s.group,
                    tab_id=paired_tab_id_by_saved_id.get(s.id, ""),
                    id=s.id,
                )
                tree.root.add_leaf(_format_row(row), data=row)
            tree.root.add_leaf(Text("\u2800"), data=_SpacerMarker())

        group_color = (
            self._omarchy_colors.get("accent")
            or self._omarchy_colors.get("color4")
            or "cyan"
        )
        group_style = Style(color=group_color, bold=True)

        # Group user-saved tabs by group name. Essentials are excluded
        # here — they render as top-level leaves above, not under a
        # Saved: header. Non-Essentials are scoped to the current
        # workspace; saved tabs from other workspaces render only when
        # their workspace is current.
        groups: dict[str, list[store.SavedTab]] = {}
        for t in self._saved:
            if t.group == ESSENTIALS_GROUP:
                continue
            if t.workspace != self._current_workspace:
                continue
            if not _match(t.title, t.url, f):
                continue
            groups.setdefault(t.group or "Unsorted", []).append(t)

        # Per-workspace collapsed-group memory. Read once per rebuild;
        # `expand=` below decides each header's initial state. The
        # set membership is keyed by group name (the user-visible
        # label). Renames invalidate stale entries — harmless: the
        # group reverts to expanded, the user collapses again, the
        # new name lands in the set on the next toggle.
        collapsed_groups = set(
            store.get_collapsed_groups(self._current_workspace)
        )
        # Per-workspace filtered-group memory. Filtered groups are
        # expanded in Textual's sense (children visible) but only
        # children paired with an open chromium tab render — saved
        # entries with an empty tab_id are skipped. Cached on the app
        # so FolderTree.render_label can pick the funnel glyph
        # without re-reading state.json on every paint.
        filtered_groups = set(
            store.get_filtered_groups(self._current_workspace)
        )
        self._filtered_groups = filtered_groups
        self._saved_nodes = {}
        for group_name in self._ordered_group_names(groups):
            items = groups[group_name]
            gnode = tree.root.add(
                Text(group_name, style=group_style),
                expand=group_name not in collapsed_groups,
                data=_GroupMarker(),
            )
            self._saved_nodes[group_name] = gnode
            is_filtered = group_name in filtered_groups
            for s in items:
                paired_tab_id = paired_tab_id_by_saved_id.get(s.id, "")
                if is_filtered and not paired_tab_id:
                    # Filtered view hides unopened saved tabs so the
                    # group condenses down to "what the user is
                    # actually looking at right now".
                    continue
                row = Row(
                    kind="saved",
                    title=s.title,
                    url=s.url,
                    group=s.group,
                    # Paired chromium tab_id (or "" if no open tab for
                    # this saved row yet). render_label matches against
                    # this so the highlight stays on just the paired tab.
                    tab_id=paired_tab_id,
                    id=s.id,
                )
                gnode.add_leaf(_format_row(row), data=row)

        # Pending new-group preview — placeholder header rendered after
        # existing groups, with the row leaf beneath it. Nothing is
        # persisted; render_label keys off `_pending_new_group_row` to
        # draw the editable buffer over the header label. Empty-string
        # key in _saved_nodes lets _restore_edit_cursor find it again
        # after Textual rebuilds the cursor on highlight events. The
        # underlying tab is the same Row dataclass as a normal saved
        # row (group="" since it's not yet persisted) so the cursor /
        # rendering path treats it identically.
        if self._pending_new_group_row is not None:
            pending_row = self._pending_new_group_row
            # Empty placeholder label — render_label paints the editable
            # buffer over it via _render_edit_label below. Keeps the
            # header layout identical to a committed group (no "Saved: "
            # prefix) so the preview reads as the future row.
            placeholder_label = Text("", style=group_style)
            gnode = tree.root.add(
                placeholder_label,
                expand=True,
                data=_GroupMarker(),
            )
            self._saved_nodes[""] = gnode
            preview_row = Row(
                kind="saved",
                title=pending_row.title,
                url=pending_row.url,
                group="",
                # Pending row is a live tab being previewed under a
                # placeholder header — nothing's persisted yet, so just
                # forward the live tab_id directly. No saved id either
                # (id assigned by store.add_saved at commit time).
                tab_id=pending_row.tab_id,
            )
            gnode.add_leaf(_format_row(preview_row), data=preview_row)
            # Hide the live tab from the loose-leaves section while it's
            # being previewed under the placeholder header — otherwise the
            # same row appears twice. Cancelling the preview rebuilds the
            # tree without this set entry, so the loose leaf comes back.
            if pending_row.kind == "live" and pending_row.tab_id:
                consumed_tab_ids.add(pending_row.tab_id)

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
            # Per-workspace view filter: loose tabs only render when
            # their workspace tag matches the current workspace.
            # Untagged tabs (transient state during a refresh between
            # observation and tag assignment) default to current so
            # they don't briefly disappear from view.
            tag = self._tab_workspace.get(t.id, self._current_workspace)
            if tag != self._current_workspace:
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
                # Session-only title override (set by `r` on a live row)
                # supersedes the chromium-reported title in render only;
                # the underlying Row keeps the real title so search
                # matching keeps hitting the actual page title.
                display_title = self._live_titles.get(t.id, t.title)
                row = Row(kind="live", title=t.title, url=t.url, tab_id=t.id)
                tree.root.add_leaf(
                    _format_row(row, title=display_title), data=row
                )

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
        if is_workspace_switch:
            # Reset cursor_line to 0 first so a workspace with no
            # cursor memory lands on the Workspace title (line 0)
            # instead of inheriting the outgoing workspace's numeric
            # cursor index. Scheduled before the restore so a saved
            # snapshot can still take precedence by calling
            # tree.move_cursor below.
            def _reset_cursor() -> None:
                tree.cursor_line = 0
            self.call_after_refresh(_reset_cursor)
        if prev_url:
            self.call_after_refresh(
                self._restore_cursor,
                tree,
                prev_url,
                prev_kind,
                prev_saved_id,
                prev_tab_id,
            )
        # Final entry: clear the dim-eval suspend so a single
        # observation runs against the *settled* cursor + active
        # state. Anything in between (Tree's internal _build firing
        # watch_cursor_line, _reset_cursor, _restore_cursor) was
        # short-circuited.
        if isinstance(tree, FolderTree):
            def _resume_dim_eval(t: FolderTree = tree) -> None:
                t._suspend_dim_eval = False
                t._reevaluate_active_dim()
            self.call_after_refresh(_resume_dim_eval)

        self._update_search_tree()

    def _restore_cursor(
        self,
        tree: Tree,
        url: str,
        kind: str,
        saved_id: str = "",
        tab_id: str = "",
    ) -> None:
        # Match by stable identity rather than URL: live rows by chromium
        # tab_id, saved rows by SavedTab.id. URL alone would land on a
        # sibling row when duplicate URLs exist across (or within)
        # groups — e.g. editing the second of two yahoo.com saved rows
        # would re-seat the cursor on the first. Falls back to URL match
        # if id/tab_id are missing (e.g. cursor was on a non-Row sentinel
        # and the caller passed empty strings).
        if kind == "live":
            for leaf in tree.root.children:
                if isinstance(leaf.data, Row) and leaf.data.kind == "live":
                    if tab_id and leaf.data.tab_id == tab_id:
                        tree.move_cursor(leaf)
                        return
                    if not tab_id and leaf.data.url == url:
                        tree.move_cursor(leaf)
                        return
        # Saved Essentials live at root; non-Essentials saved rows live
        # under group nodes. Walk both. The tab_id check matches paired
        # saved rows when the caller knows the chromium tab id but not
        # the saved id — e.g. the chromium-focus follow path passes
        # tab_id and falls through here when the tab turned out to back
        # a saved row instead of a loose leaf. Without it, follow would
        # only find the row when the saved URL still matched the live
        # URL exactly, which breaks under in-tab navigation drift.
        for leaf in tree.root.children:
            if (
                isinstance(leaf.data, Row)
                and leaf.data.kind == "saved"
                and (
                    (saved_id and leaf.data.id == saved_id)
                    or (tab_id and leaf.data.tab_id == tab_id)
                    or (not saved_id and not tab_id and leaf.data.url == url)
                )
            ):
                tree.move_cursor(leaf)
                return
        for gnode in self._saved_nodes.values():
            for leaf in gnode.children:
                if (
                    isinstance(leaf.data, Row)
                    and (
                        (saved_id and leaf.data.id == saved_id)
                        or (tab_id and leaf.data.tab_id == tab_id)
                        or (not saved_id and not tab_id and leaf.data.url == url)
                    )
                ):
                    tree.move_cursor(leaf)
                    return

    # --- search ---------------------------------------------------------

    def on_key(self, event) -> None:
        # Destructive-action confirm prompt owns the bottom bar while
        # pending. y/Y commits; n/N/Esc/anything-else cancels quietly.
        # Esc falls through to action_quit_to_browser whose top tier
        # clears the prompt via _cancel_edit, same as the other modal
        # families. prevent_default() so the focused Tree's widget
        # bindings (space/enter toggling) don't fire in parallel.
        if self._pending_confirm is not None:
            k = event.key
            if k == "escape":
                # Tier-ladder Esc handles the cancel — let it through.
                return
            event.prevent_default()
            if k in ("y", "Y"):
                self._commit_confirm()
                event.stop()
                return
            # Anything else cancels (matches the doc's "quiet rejection"
            # semantic — `n`/`N`/any other key drops the prompt without
            # a status message).
            self._pending_confirm = None
            self._update_search_tree()
            event.stop()
            return
        # Workspace switcher (`w`) — same shape as the save picker.
        # ↑/↓ cycle workspaces, Enter commits the switch, Esc cancels.
        if self._workspace_picker_index is not None:
            k = event.key
            if k == "escape":
                return
            event.prevent_default()
            if k == "enter":
                self._commit_workspace_picker()
                event.stop()
                return
            items = self._workspace_picker_items
            if k in ("up", "k", "K"):
                if items:
                    self._workspace_picker_index = (
                        self._workspace_picker_index - 1
                    ) % len(items)
                    self._update_search_tree()
                event.stop()
                return
            if k in ("down", "j", "J"):
                if items:
                    self._workspace_picker_index = (
                        self._workspace_picker_index + 1
                    ) % len(items)
                    self._update_search_tree()
                event.stop()
                return
            event.stop()
            return
        # Save-to-existing-group picker owns the bottom bar while open.
        # ↑/↓/k/j cycle groups, Enter commits, Esc cancels (the latter
        # goes through action_quit_to_browser so one path clears it).
        if self._save_picker_row is not None:
            k = event.key
            if k == "escape":
                return
            # prevent_default() is required (not just event.stop()) so the
            # focused Tree's own widget bindings for up/down don't move the
            # cursor while the picker owns the bottom bar. Same reasoning
            # as the inline-edit branch below.
            event.prevent_default()
            if k == "enter":
                self._commit_save_picker()
                event.stop()
                return
            if k in ("up", "k", "K"):
                if self._save_picker_groups:
                    self._save_picker_index = (
                        self._save_picker_index - 1
                    ) % len(self._save_picker_groups)
                    self._update_search_tree()
                event.stop()
                return
            if k in ("down", "j", "J"):
                if self._save_picker_groups:
                    self._save_picker_index = (
                        self._save_picker_index + 1
                    ) % len(self._save_picker_groups)
                    self._update_search_tree()
                event.stop()
                return
            # Swallow every other key so stray presses can't scroll the
            # tree or trigger another action under the picker.
            event.stop()
            return
        # Inline edit modes (saved-tab rename, live-tab rename, group
        # rename, new-group preview) share one buffer + cursor, dispatched
        # by which state is set. Swallows every key except Esc. Enter
        # commits via mode-specific _commit_*; Backspace/Delete/Left/Right/
        # Home/End edit the buffer; printable chars insert at the cursor.
        # All other keys are consumed silently so stray presses can't
        # scroll away or activate another row mid-edit. Esc falls through
        # to action_quit_to_browser, whose top tier cancels the edit —
        # same shape as search's Esc-cancel path.
        if self._in_any_edit_mode():
            k = event.key
            if k == "escape":
                return
            # prevent_default() tells Textual to skip widget-level binding
            # dispatch for this event (e.g. Tree's built-in space/enter
            # bindings that otherwise fire in parallel with on_key).
            # event.stop() only blocks bubbling, which isn't enough here
            # when the focused Tree's own widget bindings would still run.
            # Every edit-mode key path below must call prevent_default()
            # so keys like space don't collapse the placeholder group,
            # enter doesn't toggle its expansion, etc.
            event.prevent_default()
            if k == "enter":
                self._commit_edit()
                event.stop()
                return
            buf = self._rename_buffer
            cur = self._rename_cursor
            if k == "backspace":
                if cur > 0:
                    self._rename_buffer = buf[:cur - 1] + buf[cur:]
                    self._rename_cursor = cur - 1
                self._edit_repaint()
                event.stop()
                return
            if k == "delete":
                if cur < len(buf):
                    self._rename_buffer = buf[:cur] + buf[cur + 1:]
                self._edit_repaint()
                event.stop()
                return
            if k == "ctrl+backspace":
                # Delete word to the left — same word-boundary walk as
                # ctrl+left, then splice out the run between the new
                # cursor and the old position.
                i = cur
                while i > 0 and not buf[i - 1].isalnum():
                    i -= 1
                while i > 0 and buf[i - 1].isalnum():
                    i -= 1
                self._rename_buffer = buf[:i] + buf[cur:]
                self._rename_cursor = i
                self._edit_repaint()
                event.stop()
                return
            if k == "ctrl+shift+backspace":
                # Clear the entire edit buffer. Uses the shift modifier
                # on top of ctrl+backspace so the muscle-memory chain is
                # backspace (one char) → ctrl+backspace (one word) →
                # ctrl+shift+backspace (everything), all powered through
                # the same key.
                self._rename_buffer = ""
                self._rename_cursor = 0
                self._edit_repaint()
                event.stop()
                return
            if k == "ctrl+delete":
                n = len(buf)
                i = cur
                while i < n and not buf[i].isalnum():
                    i += 1
                while i < n and buf[i].isalnum():
                    i += 1
                self._rename_buffer = buf[:cur] + buf[i:]
                self._edit_repaint()
                event.stop()
                return
            if k == "left":
                self._rename_cursor = max(0, cur - 1)
                self._edit_repaint()
                event.stop()
                return
            if k == "right":
                self._rename_cursor = min(len(buf), cur + 1)
                self._edit_repaint()
                event.stop()
                return
            if k == "ctrl+left":
                # Word-skip: walk left through any non-word chars
                # (whitespace, URL separators like `:/?&=`) and then
                # through the word chars before them. Mirrors readline
                # / browser address-bar Ctrl+Left.
                i = cur
                while i > 0 and not buf[i - 1].isalnum():
                    i -= 1
                while i > 0 and buf[i - 1].isalnum():
                    i -= 1
                self._rename_cursor = i
                self._edit_repaint()
                event.stop()
                return
            if k == "ctrl+right":
                n = len(buf)
                i = cur
                while i < n and not buf[i].isalnum():
                    i += 1
                while i < n and buf[i].isalnum():
                    i += 1
                self._rename_cursor = i
                self._edit_repaint()
                event.stop()
                return
            if k in ("home", "ctrl+a"):
                self._rename_cursor = 0
                self._edit_repaint()
                event.stop()
                return
            if k in ("end", "ctrl+e"):
                self._rename_cursor = len(buf)
                self._edit_repaint()
                event.stop()
                return
            ch = event.character or ""
            if len(ch) == 1 and ch.isprintable():
                self._rename_buffer = buf[:cur] + ch + buf[cur:]
                self._rename_cursor = cur + 1
                self._edit_repaint()
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
        if self._in_move_mode:
            self._move_carried(+1)
            return
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        if self._in_preview_mode and not self._in_help_mode:
            self._preview_cursor_step(tree, +1)
            return
        tree.action_cursor_down()
        self._skip_spacers(tree, +1)

    def action_cursor_up(self) -> None:
        if self._in_move_mode:
            self._move_carried(-1)
            return
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        if self._in_preview_mode and not self._in_help_mode:
            self._preview_cursor_step(tree, -1)
            return
        tree.action_cursor_up()
        self._clamp_help_cursor(tree)
        self._skip_spacers(tree, -1)

    def action_jump_top(self) -> None:
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        tree.cursor_line = _HELP_FIRST_ROW if self._in_help_mode else 0
        self._skip_spacers(tree, +1)
        self._skip_non_tabs_if_previewing(tree, +1)

    def action_jump_bottom(self) -> None:
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        tree.cursor_line = max(0, tree.last_line)
        self._skip_spacers(tree, -1)
        self._skip_non_tabs_if_previewing(tree, -1)

    def action_half_page_down(self) -> None:
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        step = max(1, tree.size.height // 2)
        for _ in range(step):
            tree.action_cursor_down()
        self._skip_spacers(tree, +1)
        self._skip_non_tabs_if_previewing(tree, +1)

    def action_half_page_up(self) -> None:
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        step = max(1, tree.size.height // 2)
        for _ in range(step):
            tree.action_cursor_up()
        self._clamp_help_cursor(tree)
        self._skip_spacers(tree, -1)
        self._skip_non_tabs_if_previewing(tree, -1)

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

    def _skip_non_tabs_if_previewing(self, tree: Tree, direction: int) -> None:
        """Preview mode cycles tabs — so motion keys should only land on
        `Row` leaves. Skip past Workspace/group-header/spacer rows in
        `direction` (+1 = down, -1 = up) until the cursor reaches a
        tab. If motion can't advance (cursor_line unchanged after an
        action step), stop rather than looping forever — e.g. when the
        tree has no Row nodes at all, or when `g` in preview lands on
        the first non-Row and there's nothing past it. Does NOT wrap:
        jump (`g`/`G`) and half-page (`Ctrl+D`/`U`) are "move a chunk"
        actions and teleporting to the other end mid-skip would be
        surprising. Wrap behavior lives in `_preview_cursor_step`,
        dedicated to single-step j/k/J/K. Skipped in help mode (help
        has its own row types and cursor floor)."""
        if not self._in_preview_mode or self._in_help_mode:
            return
        while True:
            node = tree.cursor_node
            if node is None or isinstance(node.data, Row):
                return
            prev_line = tree.cursor_line
            if direction > 0:
                tree.action_cursor_down()
            else:
                tree.action_cursor_up()
            if tree.cursor_line == prev_line:
                return

    def _preview_cursor_step(self, tree: Tree, direction: int) -> None:
        """Preview-mode single-step j/k/J/K: move to the next tab row
        in `direction`, wrapping at the tree edges like the external
        Super+Alt+J/K cycle does. Steps one cursor action at a time,
        skipping Workspace / group-header / spacer rows. On an edge
        hit (`cursor_line` unchanged after the action step), wrap to
        the opposite end and continue the search from there. The loop
        is bounded by `last_line + 2` so an empty-tabs tree can't spin
        forever — it returns with the cursor wherever the last step
        left it."""
        last_line = max(0, tree.last_line)
        if last_line <= 0:
            return
        for _ in range(last_line + 2):
            prev_line = tree.cursor_line
            if direction > 0:
                tree.action_cursor_down()
            else:
                tree.action_cursor_up()
            if tree.cursor_line == prev_line:
                tree.cursor_line = 0 if direction > 0 else last_line
            node = tree.cursor_node
            if node is not None and isinstance(node.data, Row):
                return

    def action_collapse(self) -> None:
        # During inline rename the Left arrow moves the edit cursor; the
        # binding must not collapse the parent group out from under the
        # row being edited (which also hides the inline edit field).
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        # Group header: cycle one step toward less visibility
        # (expanded → filtered → collapsed). Already-collapsed groups
        # fall through to the parent-move below.
        if isinstance(node.data, _GroupMarker):
            if self._cycle_group_state(node, direction=-1):
                return
        if node.parent is not None:
            # move_cursor (not select_node) — select_node posts
            # Tree.NodeSelected, which our handler interprets as an Enter
            # press AND which Tree's own auto-expand hook reacts to by
            # toggling the group. Both are wrong for "just move the cursor
            # up to the parent group".
            tree.move_cursor(node.parent)

    def action_expand(self) -> None:
        if self._in_modal_state():
            return
        self._activate_cursor()
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        # Group header: cycle one step toward more visibility
        # (collapsed → filtered → expanded). Terminal at expanded.
        if isinstance(node.data, _GroupMarker):
            self._cycle_group_state(node, direction=+1)

    def _cycle_group_state(self, node, direction: int) -> bool:
        """Advance the group's state in the expanded/filtered/collapsed
        ladder by `direction` (+1 toward expanded, -1 toward collapsed).
        Mutates the persisted sets directly and rebuilds; bypasses
        Textual's node.expand()/collapse() so on_tree_node_*
        handlers don't re-derive a binary state out of the three-state
        intent. Returns True iff the state actually changed."""
        if not isinstance(node.data, _GroupMarker):
            return False
        group_name = next(
            (g for g, n in self._saved_nodes.items() if n is node),
            "",
        )
        # Empty key = pending new-group preview placeholder; nothing to
        # persist for it.
        if not group_name:
            return False
        ws_id = self._current_workspace
        collapsed = set(store.get_collapsed_groups(ws_id))
        filtered = set(store.get_filtered_groups(ws_id))
        if group_name in collapsed:
            current = "collapsed"
        elif group_name in filtered:
            current = "filtered"
        else:
            current = "expanded"
        ladder = ["collapsed", "filtered", "expanded"]
        new_idx = ladder.index(current) + direction
        if new_idx < 0 or new_idx >= len(ladder):
            return False
        new_state = ladder[new_idx]
        collapsed.discard(group_name)
        filtered.discard(group_name)
        if new_state == "collapsed":
            collapsed.add(group_name)
        elif new_state == "filtered":
            filtered.add(group_name)
        store.set_collapsed_groups(ws_id, list(collapsed))
        store.set_filtered_groups(ws_id, list(filtered))
        self._rebuild_tree()
        return True

    def action_focus_search(self) -> None:
        # Every action bound to a printable key needs a rename-mode gate:
        # on_key's printable branch already inserts the char into the
        # buffer, but Textual in this version still fires the App-level
        # binding in parallel (same leak as arrow keys → action_collapse).
        # Without the gate, pressing `/`, `o`, `s`, `d`, `p`, `P`, `r`, `?`
        # mid-edit would double-fire the action and, e.g., open a tab or
        # reset the rename buffer on top of the user's keystroke.
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        self._in_search_mode = True
        self._cursor_on = True
        self._rebuild_tree()

    def action_activate(self) -> None:
        if self._in_modal_state():
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

    def action_new_tab(self) -> None:
        """Open a new chromium tab on chrome://newtab/ and bring
        chromium to focus — same intent as Ctrl+T inside chromium,
        so the user can start typing in the new-tab page's search
        box (or omnibox) immediately. The tab gets tagged to the
        current workspace by the regular `_sync_tab_workspace_tags`
        pass on the next refresh; `_mark_active` here drives the
        rebuild and updates `_workspace_active_tab[current]` via
        `_remember_active_for_current_workspace`, so coming back
        to bm via Esc lands the cursor on the new tab."""
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        if not launcher.ensure_up():
            self._set_status("chromium not reachable")
            return
        try:
            tab = cdp.new_tab("chrome://newtab/")
        except Exception as exc:
            self._set_status(f"New tab failed ({exc})")
            return
        actions.raise_chromium()
        # Refresh BEFORE _mark_active so the new tab lands in
        # self._live before _rebuild_tree runs — same ordering as
        # _open_saved. Without the reorder, _mark_active's rebuild
        # fires with stale `_live` and the new tab renders as a
        # delayed entry.
        self._refresh_live()
        self._mark_active(tab.url, tab.id)
        self._set_status("New Tab")

    def action_open_saved(self) -> None:
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._open_saved(row)

    def action_yank_url(self) -> None:
        """Copy the URL of the row the cursor is on to the system
        clipboard. Prefers the *live* chromium URL (looked up by tab_id
        in self._live) over the row's stored url, so a saved row whose
        tab has navigated away from the saved URL yanks what's actually
        in the address bar — not the stale saved value. Unpaired saved
        rows fall back to the saved URL since that's the only URL we
        have for them."""
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        url = ""
        if row.tab_id:
            for t in self._live:
                if t.id == row.tab_id:
                    url = t.url
                    break
        if not url:
            url = row.url
        if not url:
            return
        if actions.copy_to_clipboard(url):
            self._set_status("Copied URL")
        else:
            self._set_status("Copy failed (wl-copy missing?)")

    def action_yank_saved_url(self) -> None:
        """Copy the saved URL of the row the cursor is on. Saved-only —
        on a loose live tab (no saved counterpart) shows a status note
        and does nothing, since there's no saved URL to yank. Pair to
        `y`, which copies the live address-bar URL; `Y` is what was
        bookmarked, regardless of where the paired tab has navigated."""
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        if row.kind != "saved":
            self._set_status("Not a saved tab")
            return
        if not row.url:
            return
        if actions.copy_to_clipboard(row.url):
            self._set_status("Copied saved URL")
        else:
            self._set_status("Copy failed (wl-copy missing?)")

    # --- move/reorder mode ---------------------------------------------

    def action_enter_move_mode(self) -> None:
        """Enter MOVE mode for the row/group the cursor is on. While
        in mode, j/k swap the carried item with its in-scope neighbor;
        m or Esc exits. Cursor on a non-movable row (workspace title,
        spacer, divider) shows a status note and stays out of mode."""
        # m toggles out of move mode. Checked ahead of _in_modal_state
        # because move mode itself sets that True.
        if self._in_move_mode:
            self._exit_move_mode()
            return
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            self._set_status("Nothing to move")
            return
        data = node.data
        if isinstance(data, _GroupMarker):
            # Pending new-group preview header has empty key in
            # _saved_nodes; reject it — there's nothing persisted to
            # reorder. Real group headers all have a non-empty name.
            group_name = next(
                (g for g, n in self._saved_nodes.items() if n is node),
                "",
            )
            if not group_name:
                self._set_status("Can't move this row")
                return
        elif isinstance(data, Row):
            if data.kind not in ("saved", "live"):
                self._set_status("Can't move this row")
                return
        else:
            self._set_status("Can't move this row")
            return
        self._in_move_mode = True
        # Suppress Tree's auto-toggle-on-select while reordering. Its
        # built-in @on(NodeSelected) handler runs before our App-level
        # on_tree_node_selected, so an Enter on a group header would
        # collapse/expand the group AND post NodeCollapsed/NodeExpanded
        # (which our persistence handler then writes to disk) before we
        # got the chance to translate Enter into "exit move mode".
        # Flipping auto_expand off short-circuits that listener for
        # the duration of the mode; _exit_move_mode restores it.
        tree.auto_expand = False
        self._update_search_tree()

    def _exit_move_mode(self) -> None:
        if not self._in_move_mode:
            return
        self._in_move_mode = False
        self.query_one("#tree", Tree).auto_expand = True
        self._update_search_tree()

    def _move_carried(self, direction: int) -> None:
        """Swap the carried row/group with its sibling in `direction`
        (+1 = down, -1 = up). Scope is determined by the cursor row's
        kind: saved-in-group, essentials, group header, or loose live
        tab. Out-of-scope or no-sibling cases silently no-op so j/k at
        section boundaries don't drop the user out of move mode."""
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        data = node.data
        moved = False
        restore_group: Optional[str] = None
        if isinstance(data, _GroupMarker):
            group_name = next(
                (g for g, n in self._saved_nodes.items() if n is node),
                "",
            )
            if not group_name:
                return
            if self._move_group_header(group_name, direction):
                moved = True
                restore_group = group_name
        elif isinstance(data, Row) and data.kind == "saved":
            if data.group == ESSENTIALS_GROUP:
                moved = self._move_saved_in_essentials(data, direction)
            else:
                moved = self._move_saved_in_group(data, direction)
        elif isinstance(data, Row) and data.kind == "live":
            moved = self._move_live_tab(data, direction)
        if not moved:
            return
        # Stash before rebuild — _rebuild_tree's cursor restore reads
        # the current node, but we want the cursor to follow the moved
        # row to its new line, not stay parked on the (already-mutated)
        # current line. For Row data the existing url+id restore path
        # handles it; for group headers the restore path bails (data
        # isn't a Row), so we re-seat after the rebuild manually.
        self._rebuild_tree()
        if restore_group is not None:
            def _seat_group_cursor(name: str = restore_group) -> None:
                target = self._saved_nodes.get(name)
                if target is not None:
                    self.query_one("#tree", Tree).move_cursor(target)
            self.call_after_refresh(_seat_group_cursor)

    def _move_group_header(self, group_name: str, direction: int) -> bool:
        """Reorder `group_name` within the workspace's group order list.
        Builds the full effective order (persisted + any newly-discovered
        groups appended) so the swap also ratchets discovered groups into
        the persisted list — otherwise the next rebuild would re-derive
        their positions and visually unmove what the user just moved."""
        ws_id = self._current_workspace
        # Effective order = current visible group sequence under the
        # workspace, in the same order _ordered_group_names produced
        # for the most recent rebuild. Re-derive from _saved_nodes
        # (insertion order matches render order).
        effective = list(self._saved_nodes.keys())
        # Drop the pending-new-group placeholder (empty key) — it isn't
        # persistable and can't participate in reorder.
        effective = [g for g in effective if g]
        try:
            idx = effective.index(group_name)
        except ValueError:
            return False
        target = idx + direction
        if target < 0 or target >= len(effective):
            return False
        effective[idx], effective[target] = effective[target], effective[idx]
        store.set_group_order(ws_id, effective)
        return True

    def _move_saved_in_group(self, row: Row, direction: int) -> bool:
        """Swap `row` with the sibling in the same (group, workspace)
        slice of self._saved. Persists by writing the full _saved list
        back via store.save_all — file order is render order, so any
        swap inside the slice produces the right visual result without
        a separate ordering field."""
        ws_id = self._current_workspace
        # Indices into self._saved that share the group + workspace.
        sibling_indices = [
            i for i, t in enumerate(self._saved)
            if t.group == row.group and t.workspace == ws_id
        ]
        return self._swap_in_saved(row.id, sibling_indices, direction)

    def _move_saved_in_essentials(self, row: Row, direction: int) -> bool:
        """Swap `row` with the sibling Essentials entry. Essentials are
        global (workspace == ""), so the slice ignores workspace."""
        sibling_indices = [
            i for i, t in enumerate(self._saved)
            if t.group == ESSENTIALS_GROUP
        ]
        return self._swap_in_saved(row.id, sibling_indices, direction)

    def _swap_in_saved(
        self, saved_id: str, sibling_indices: list[int], direction: int
    ) -> bool:
        """Swap the position of `saved_id` with its in-section neighbor
        in self._saved, then persist. Returns False (no-op) when the
        row isn't in the section or already at the boundary."""
        try:
            position = next(
                p for p, i in enumerate(sibling_indices)
                if self._saved[i].id == saved_id
            )
        except StopIteration:
            return False
        target = position + direction
        if target < 0 or target >= len(sibling_indices):
            return False
        i_a = sibling_indices[position]
        i_b = sibling_indices[target]
        self._saved[i_a], self._saved[i_b] = self._saved[i_b], self._saved[i_a]
        store.save_all(self._saved)
        return True

    def _move_live_tab(self, row: Row, direction: int) -> bool:
        """Swap `row`'s position in self._live_order with the next
        in-scope loose live tab. Scope = same workspace AND not paired
        with a saved row (paired live tabs render under their saved
        header, not in Open Tabs, so they aren't reorder-eligible
        siblings). Mutates _live_order in place; not persisted —
        chromium tab ids aren't stable across restarts.

        Also re-sorts self._live to match. _rebuild_tree (called
        right after this returns) reads from self._live, not
        _live_order, and _refresh_live's diff gate only triggers a
        rebuild on (id, url, title) set differences — a pure reorder
        wouldn't fire it. Without re-sorting here, _live and
        _live_order would desync until something else forced a
        refresh-driven rebuild, and a second j/k would compute its
        position from the new _live_order against the stale tree.
        """
        ws_id = self._current_workspace
        paired_tab_ids = set(self._saved_session_tab_id.values())
        loose_tab_ids = [
            tid for tid in self._live_order
            if self._tab_workspace.get(tid, ws_id) == ws_id
            and tid not in paired_tab_ids
        ]
        try:
            position = loose_tab_ids.index(row.tab_id)
        except ValueError:
            return False
        target = position + direction
        if target < 0 or target >= len(loose_tab_ids):
            return False
        a = loose_tab_ids[position]
        b = loose_tab_ids[target]
        i_a = self._live_order.index(a)
        i_b = self._live_order.index(b)
        self._live_order[i_a], self._live_order[i_b] = (
            self._live_order[i_b],
            self._live_order[i_a],
        )
        self._live = self._stable_sort_live(self._live)
        return True

    def _ordered_group_names(
        self, groups: dict[str, list[store.SavedTab]]
    ) -> list[str]:
        """Group names in the order _rebuild_tree should render them.
        Persisted user-chosen order wins; groups not yet in the
        persisted list are appended in creation order (= first-
        appearance in self._saved iteration, since `add_saved`
        appends). Stale persisted entries (renamed/deleted groups)
        are filtered out so they don't leave gaps in the effective
        order."""
        ws_id = self._current_workspace
        persisted = store.get_group_order(ws_id)
        seen = set()
        ordered: list[str] = []
        for name in persisted:
            if name in groups and name not in seen:
                ordered.append(name)
                seen.add(name)
        for s in self._saved:
            if s.group == ESSENTIALS_GROUP:
                continue
            if s.workspace != ws_id:
                continue
            if s.group in groups and s.group not in seen:
                ordered.append(s.group)
                seen.add(s.group)
        return ordered

    def _activate_saved(self, row: Row, *, raise_window: bool) -> str:
        """Activate `row` in chromium and return the tab_id actually
        hit. Uses `row.tab_id` directly when _rebuild_tree has already
        paired the saved row with an open chromium tab; otherwise
        always creates a fresh chromium tab.

        Deliberately *not* `actions.open_or_switch` for the unpaired
        path — that helper find-or-creates by URL match, which would
        let a loose live tab whose URL happens to match the saved
        entry get adopted as the saved row's session. The user's mental
        model is "saved tabs are their own sessions"; a loose tab the
        user navigated to the same URL stays loose unless the user
        explicitly chose to claim it (e.g. via `s`).
        """
        if row.tab_id:
            cdp.activate(row.tab_id)
            if raise_window:
                actions.raise_chromium()
            return row.tab_id
        tab = cdp.new_tab(row.url)
        if raise_window:
            actions.raise_chromium()
        return tab.id

    def _open_saved(self, row: Row) -> None:
        try:
            tab_id = self._activate_saved(row, raise_window=True)
        except Exception as exc:
            self._set_status(f"Failed to open ({exc})")
            return
        # Claim this chromium tab for the saved row for the rest of
        # the session — pairing in _rebuild_tree consults this map
        # before any URL-based match, so the saved row stays paired
        # even when the URL changes inside the tab (link clicks,
        # redirects, in-page nav).
        if row.kind == "saved" and tab_id and row.id:
            self._claim_session_tab(row.id, tab_id)
        # Order matters here. _refresh_live re-polls chromium so a
        # tab that _activate_saved just *created* (cdp.new_tab path)
        # lands in self._live before the next rebuild. Without this,
        # _mark_active's rebuild would run with the stale tab list,
        # the session-pass reaper would see tab_id missing from
        # live_ids and silently delete the claim we just made — the
        # saved row would stay dim and the new tab would render as a
        # loose leaf instead.
        self._refresh_live()
        self._mark_active(row.url, tab_id)

    def _claim_session_tab(self, saved_id: str, tab_id: str) -> None:
        """Record that the saved row with id `saved_id` owns chromium
        `tab_id` for this session, revoking any prior claim by other
        saved rows on the same tab. Keeps the session map one-to-one
        so the pairing pass in _rebuild_tree can't pin the same tab id
        to two saved rows when activate-or-open routes them to the
        same live tab."""
        if not saved_id:
            return
        stale = [
            sid for sid, tid in self._saved_session_tab_id.items()
            if tid == tab_id and sid != saved_id
        ]
        for sid in stale:
            del self._saved_session_tab_id[sid]
        self._saved_session_tab_id[saved_id] = tab_id

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
        self._remember_active_for_current_workspace()
        # Full tree rebuild is the simplest way to get both the old and
        # new active rows to repaint. Cheap in practice.
        self._rebuild_tree()

    def action_cycle_workspace(self) -> None:
        """Cycle directly to the next workspace in the array — no
        picker UI. Wraps from last back to first. Bound to `;` (and
        triggered by SIGRTMIN from `bm workspace next` for the global
        Super+Alt+; binding). Same recovery dance as the picker
        commit (clear pairings, flip the URL-seed gate) so the
        incoming workspace's saved↔live pairing re-runs against the
        currently-tagged tabs."""
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        self._cycle_workspace_step()

    def _displayed_active_tab_id(self) -> str:
        """The tab id to render as 'active' (color11 highlight) in
        the current workspace.

        Intentionally separate from `_active_tab_id`: the latter
        tracks what chromium currently has focused (the source of
        truth for `_refresh_live`'s active_changed detection and the
        cross-workspace follow gate), while this method answers
        "what should the user see highlighted in the workspace
        they're looking at." After a manual workspace switch they
        can diverge — the user is now viewing workspace B's tree but
        chromium is still focused on a tab in A; the per-workspace
        remembered active fills that gap so each workspace shows its
        own last-active row.

        Without this split, the highlight would key on the global
        `_active_tab_id` and a manual `;` cycle would never show a
        ghost highlight in the new workspace; worse, *updating*
        `_active_tab_id` to fake one would trip `active_changed` on
        the very next refresh tick (chromium's focus didn't change,
        but our `_active_tab_id` did) and the cross-workspace follow
        would snap back to the workspace owning chromium's actual
        focused tab.
        """
        return self._workspace_active_tab.get(
            self._current_workspace, ""
        )

    def _remember_active_for_current_workspace(self) -> None:
        """Record the current `_active_tab_id` as the remembered
        active tab for the current workspace, but only when that tab
        actually belongs in the current workspace's view (so a
        cross-workspace ghost focus doesn't pollute the slot). Called
        after every `_active_tab_id` update — both bm-driven (Enter,
        peek, etc.) and chromium-driven (manual tab switch in the
        browser)."""
        if not self._current_workspace or not self._active_tab_id:
            return
        if self._workspace_for_tab(self._active_tab_id) == self._current_workspace:
            self._workspace_active_tab[self._current_workspace] = self._active_tab_id

    def _restore_workspace_active(self, target_id: str) -> None:
        """Validate the incoming workspace's remembered active tab on
        a manual switch — drops the slot if the tab has closed since
        last visit. **Doesn't touch `_active_tab_id` / `_active_url`**
        — those track chromium's actual focused tab (used by
        `_refresh_live`'s active_changed gate). The render path keys
        on `_displayed_active_tab_id()`, which reads
        `_workspace_active_tab[current]` directly, so the highlight
        already follows the per-workspace slot. If we *also* mutated
        `_active_tab_id` here, the next refresh tick would see
        `chromium_focused.id != _active_tab_id` (chromium didn't
        change, but we did) and the cross-workspace follow would
        snap right back to whatever workspace owns chromium's actual
        focused tab — exactly the "switches to the same workspace"
        bug. Leaving `_active_tab_id` alone keeps the next refresh
        tick a no-op."""
        remembered = self._workspace_active_tab.get(target_id, "")
        if not remembered:
            return
        live_match = next(
            (t for t in self._live if t.id == remembered), None
        )
        if live_match is None:
            self._workspace_active_tab.pop(target_id, None)

    def _activate_workspace_remembered_tab(self) -> None:
        """Tell chromium to focus the current workspace's remembered
        active tab, without stealing keyboard focus from whichever
        window has it now (bm when the user pressed `;`/`w` in the
        TUI, chromium when they pressed Super+Alt+; routed via
        SIGRTMIN). Same focus-restore dance as _peek_row.

        Without this, a manual workspace switch only flips the bm
        view — chromium keeps showing whatever tab it had focused
        before, so a tab from the *outgoing* workspace stays visible
        until the user clicks something in the new tree. Preview
        mode hid the gap because its cursor-move peek activated
        rows in chromium for free; with preview off the divergence
        was visible.

        Updates `_active_tab_id` / `_active_url` to mirror the
        activation so the next `_refresh_live` tick observes no
        `active_changed` and skips a redundant rebuild. Call only
        after `_restore_workspace_active` has dropped stale slots,
        so the live_match check below is mostly redundant defense."""
        remembered = self._workspace_active_tab.get(
            self._current_workspace, ""
        )
        if not remembered:
            return
        live_match = next(
            (t for t in self._live if t.id == remembered), None
        )
        if live_match is None:
            return
        prev_addr = _active_window_address()
        try:
            cdp.activate(remembered)
        except Exception as exc:
            self._set_status(f"Activate failed ({exc})")
            return
        self._active_tab_id = remembered
        self._active_url = live_match.url
        # Mark this tab as the in-flight target so the next refresh
        # tick suppresses active_changed processing until chromium's
        # MRU has caught up — see _pending_workspace_active_tab_id.
        self._pending_workspace_active_tab_id = remembered
        if prev_addr:
            _focus_window(prev_addr)
            self.set_timer(0.08, lambda addr=prev_addr: _focus_window(addr))

    def _save_workspace_cursor(self, workspace_id: str) -> None:
        """Snapshot the current cursor's row identity into the
        per-workspace cursor map. Called by every workspace-switch
        path immediately before the workspace flip so the outgoing
        workspace remembers where the user was; on re-entry the
        rebuild's pending-cursor slot is seeded from this map. Drops
        the slot when the cursor is on a non-Row sentinel (Workspace
        title, group header, spacer) so re-entry defaults to line 0
        cleanly instead of restoring stale row info."""
        if not workspace_id:
            return
        try:
            tree = self.query_one("#tree", Tree)
        except Exception:
            return
        cur_node = tree.cursor_node
        if cur_node is not None and isinstance(cur_node.data, Row):
            self._workspace_cursors[workspace_id] = {
                "url": cur_node.data.url,
                "kind": cur_node.data.kind,
                "saved_id": cur_node.data.id,
                "tab_id": cur_node.data.tab_id,
            }
        else:
            self._workspace_cursors.pop(workspace_id, None)

    def _cycle_workspace_step(self) -> None:
        if self._in_move_mode:
            # Same rationale as _cycle_step's gate: workspace cycling
            # while reordering would yank the carried row out from
            # under the user. Make them cancel MOVE manually.
            return
        if not self._workspaces:
            return
        if len(self._workspaces) < 2:
            self._set_status("Only one workspace")
            return
        current_idx = next(
            (i for i, w in enumerate(self._workspaces)
             if w.id == self._current_workspace),
            0,
        )
        next_idx = (current_idx + 1) % len(self._workspaces)
        target = self._workspaces[next_idx]
        self._save_workspace_cursor(self._current_workspace)
        self._pending_workspace_cursor = (
            self._workspace_cursors.get(target.id) or {}
        )
        self._current_workspace = target.id
        store.set_current_workspace(target.id)
        # Restore the incoming workspace's remembered active tab so
        # the highlight reappears on the row that was active there
        # last, instead of going dark (the global `_active_tab_id`
        # still points at chromium's currently-focused tab, which
        # may live in a different workspace and therefore wouldn't
        # render in the new view).
        self._restore_workspace_active(target.id)
        self._activate_workspace_remembered_tab()
        # Re-arm URL-pair seeding for the incoming workspace's saved
        # rows. The session map is preserved across the cycle —
        # entries are keyed on saved_id (workspace-agnostic), and
        # chromium tabs persist across workspace switches, so a
        # saved↔tab pair the user established before cycling is still
        # valid when they cycle back. Clearing it would unpair every
        # saved row in the outgoing workspace and the next click on
        # one would create a duplicate chromium tab.
        self._initial_pair_done = False
        self._set_status(f"Switched to {target.name}")
        self._rebuild_tree()
        self._update_search_tree()

    def action_switch_workspace(self) -> None:
        """Open the workspace switcher picker. Same shape as the save
        picker — bottom-bar two-line layout, ↑/↓ cycle, Enter commits,
        Esc cancels. Always opens at index 0 (predictable cursor).
        Valid from any cursor location."""
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        if not self._workspaces:
            return
        # Capture the workspace list at picker open so list changes
        # via concurrent CLI calls don't shift the index under the
        # user. Mirrors the save picker's _save_picker_groups capture.
        self._workspace_picker_items = list(self._workspaces)
        self._workspace_picker_index = 0
        self._update_search_tree()

    def _commit_workspace_picker(self) -> None:
        """Switch to the workspace highlighted in the picker. The
        next _rebuild_tree filters loose leaves by the new workspace
        tag, and saved groups by the workspace id; the activate
        below pulls chromium's focused tab into the new workspace
        too, so the browser doesn't keep showing a tab from the
        outgoing one."""
        items = self._workspace_picker_items
        idx = self._workspace_picker_index or 0
        self._workspace_picker_index = None
        self._workspace_picker_items = []
        if not items or idx >= len(items):
            self._update_search_tree()
            return
        target = items[idx]
        if target.id == self._current_workspace:
            self._update_search_tree()
            return
        self._save_workspace_cursor(self._current_workspace)
        self._pending_workspace_cursor = (
            self._workspace_cursors.get(target.id) or {}
        )
        self._current_workspace = target.id
        store.set_current_workspace(target.id)
        self._restore_workspace_active(target.id)
        self._activate_workspace_remembered_tab()
        # Re-arm URL-pair seeding for the incoming workspace's saved
        # rows so they get URL-matched against the live tabs that
        # haven't been seeded yet. The session map persists across
        # the switch — see _cycle_workspace_step for the rationale.
        self._initial_pair_done = False
        self._set_status(f"Switched to {target.name}")
        self._rebuild_tree()
        self._update_search_tree()

    def action_new_workspace(self) -> None:
        """Preview-before-commit new workspace. Inserts a placeholder
        Workspace row in inline edit mode prefilled with `Workspace`.
        Enter creates the workspace and switches into it; Esc rolls
        back. Mutually exclusive with every other modal state."""
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        self._pending_new_workspace = True
        self._rename_buffer = "Workspace"
        self._rename_cursor = len(self._rename_buffer)
        self._cursor_on = True
        self._rebuild_tree()
        self._update_search_tree()

    def _commit_new_workspace(self) -> None:
        """Persist the pending new workspace and switch into it. Empty
        buffer is a no-op cancel (matches the rest of the inline-edit
        family)."""
        new_name = (self._rename_buffer or "").strip()
        self._pending_new_workspace = False
        self._rename_buffer = ""
        self._rename_cursor = 0
        if not new_name:
            self._rebuild_tree()
            self._update_search_tree()
            return
        new_ws = store.add_workspace(new_name)
        self._workspaces = store.load_workspaces()
        # Save the outgoing workspace's cursor so a later switch back
        # lands on the same row. The new workspace has no prior
        # cursor memory; signal "workspace switch, no memory" with an
        # empty dict so the rebuild's cursor-reset branch fires and
        # the cursor lands on row 0 instead of inheriting the
        # outgoing workspace's numeric cursor_line.
        self._save_workspace_cursor(self._current_workspace)
        self._pending_workspace_cursor = {}
        self._current_workspace = new_ws.id
        store.set_current_workspace(new_ws.id)
        # New workspace has no remembered active tab — clear so the
        # tree renders without a highlight (any subsequent activation
        # seeds the slot).
        self._restore_workspace_active(new_ws.id)
        # Brand-new workspace has no saved rows, so URL-pair seeding
        # is a no-op here, but flip the gate anyway for symmetry with
        # the switch/cycle paths. Session map is preserved.
        self._initial_pair_done = False
        self._set_status(f"Created {new_name}")
        self._rebuild_tree()
        self._update_search_tree()

    def action_save_selected(self) -> None:
        # Save the tab highlighted in the TUI — NOT chromium's active tab.
        # The CLI's `bm save` still uses actions.save_focused() for the
        # "save whatever chromium is showing right now" workflow (useful
        # from a hyprland keybind without opening bm). In the TUI, the
        # user has a cursor; respect it.
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            self._set_status("No tab selected")
            return
        # Picker mode enters via `s`; destination chosen from existing
        # user-created groups plus Essentials pinned at the bottom of
        # the list (rendered as `[Essentials]` in the bottom bar to
        # signal it's the special bucket, not a folder). Live rows →
        # save (add_saved). Saved rows → move (move_saved); both flows
        # reuse the same picker UI and _commit_save_picker branches on
        # kind. Essentials always present means the picker is never
        # empty — `S` is still the create-new-group flow.
        picker_groups = self._user_group_names() + [ESSENTIALS_GROUP]
        # Always open the picker at the top of the list so the cursor
        # position is predictable regardless of prior history. (Earlier
        # iteration defaulted to row.group / _last_save_group, which
        # made the start position depend on hidden state.)
        self._save_picker_row = row
        self._save_picker_groups = picker_groups
        self._save_picker_index = 0
        self._update_search_tree()

    def action_save_new_group(self) -> None:
        # Preview-before-commit: insert a placeholder header and the tab
        # leaf into the tree (pending state, nothing persisted) and
        # enter inline edit mode on the header. Enter commits via
        # store.add_saved with the typed name as the group; Esc rolls
        # both back cleanly. Mutually exclusive with every other modal
        # state (edit + save picker).
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        row = self._selected_row()
        if row is None:
            self._set_status("No tab selected")
            return
        if row.kind == "saved":
            self._set_status("Already saved")
            return
        self._pending_new_group_row = row
        # Sensible default — Enter without editing creates a group named
        # "Group" (or appends the tab to it if one already exists).
        # Cursor at end so backspace + retype is the natural edit path.
        self._rename_buffer = "Group"
        self._rename_cursor = len(self._rename_buffer)
        self._cursor_on = True
        self._rebuild_tree()

    def action_edit_url(self) -> None:
        # Inline edit of a saved/essential row's URL. Mirrors the rename
        # flow: seeds the shared buffer with the current URL, parks the
        # cursor at the end, and lets on_key drive printable / arrow /
        # backspace edits until Enter (commit) or Esc (cancel). Live
        # rows are skipped — chromium owns their URL.
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        if row.kind != "saved":
            self._set_status("Only saved tabs can have their URL edited")
            return
        self._url_edit_url = row.url
        self._url_edit_saved_id = row.id
        self._rename_buffer = row.url
        self._rename_cursor = len(row.url)
        self._cursor_on = True
        self._rebuild_tree()

    def _user_group_names(self) -> list[str]:
        """Distinct group names from self._saved scoped to the current
        workspace, Essentials excluded, sorted alphabetically. Used by
        the save-to-existing picker — only groups in *this* workspace
        appear (group names are unique per-workspace, so a `Reading` in
        Personal and a `Reading` in Work are independent)."""
        names = {
            t.group or "Unsorted"
            for t in self._saved
            if t.group != ESSENTIALS_GROUP
            and t.workspace == self._current_workspace
        }
        return sorted(names)

    def _current_workspace_name(self) -> str:
        """Lookup the name of the currently-active workspace. Returns
        an empty string when no workspaces are loaded yet (transient
        startup state) — callers fall back to a literal label."""
        for w in self._workspaces:
            if w.id == self._current_workspace:
                return w.name
        return ""

    def action_delete_saved(self) -> None:
        # Dispatcher: every `d` invocation routes through the shared
        # destructive-action confirm prompt. Row-type-specific handler
        # fires on `y`/`Y`. Workspace/group-header rows have data that
        # isn't a `Row`, so we read tree.cursor_node directly rather
        # than going through _selected_row (which only returns Row data).
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        data = node.data
        # Workspace row → confirm + destroy workspace.
        if isinstance(data, _WorkspaceMarker):
            if len(self._workspaces) <= 1:
                self._set_status("Cannot delete the only workspace")
                return
            self._open_confirm(
                "delete_workspace",
                self._current_workspace,
                "Delete workspace?",
            )
            return
        # Group header → confirm + destroy every member tab.
        if isinstance(data, _GroupMarker):
            group_name = self._group_name_for_node(node)
            if not group_name:
                return
            self._open_confirm(
                "delete_group",
                group_name,
                "Delete group?",
            )
            return
        if not isinstance(data, Row):
            return
        row = data
        # Loose live row → confirm + close chromium tab.
        if row.kind == "live":
            if not row.tab_id:
                return
            self._open_confirm(
                "close_live", row.tab_id, "Delete open tab?",
            )
            return
        # Saved row — distinguish Essentials (global) from regular
        # saved rows so the prompt names the type accurately.
        if row.group == ESSENTIALS_GROUP:
            self._open_confirm(
                "delete_essential", row.id, "Delete essential?",
            )
            return
        self._open_confirm(
            "delete_saved", row.id, "Delete saved tab?",
        )

    def _group_name_for_node(self, node) -> str:
        """Recover the group name for a group-header tree node by
        reverse-lookup against self._saved_nodes (which _rebuild_tree
        populates with `{group_name: TreeNode}`). Empty string for the
        new-group preview placeholder, which is keyed under "" — `d`
        on that placeholder should be a no-op (the user already has
        Esc to cancel)."""
        for name, n in self._saved_nodes.items():
            if n is node and name:
                return name
        return ""

    def action_unload_tab(self) -> None:
        # `u` is `d` minus the second-press delete: close the live tab
        # (loose live row, or the paired tab on a saved row) and stop
        # there. On an unpaired saved row, no-op — `u` never touches
        # saved-tabs.json, so muscle memory of "u just closes" stays
        # predictable across row kinds.
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        if not row.tab_id:
            return
        try:
            cdp.close_tab(row.tab_id)
        except Exception as exc:
            self._set_status(f"Failed to close ({exc})")
            return
        self._set_status("Closed Tab")
        self._refresh_live()

    def action_reload_saved(self) -> None:
        # `R` reloads a saved row from its canonical URL: close the
        # paired live tab (if any), drop its session claim, then open a
        # fresh chromium tab at row.url and re-claim it. Net effect:
        # any in-tab drift (link clicks, redirects) is undone and the
        # row is paired with a tab whose URL matches saved-tabs.json
        # again. Live rows are rejected — they have no canonical URL
        # to reload from; chromium owns their URL.
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        if row.kind != "saved":
            self._set_status("Only saved tabs can be reloaded")
            return
        if row.tab_id:
            try:
                cdp.close_tab(row.tab_id)
            except Exception as exc:
                self._set_status(f"Failed to reload ({exc})")
                return
            if row.id:
                self._saved_session_tab_id.pop(row.id, None)
        try:
            tab = cdp.new_tab(row.url)
        except Exception as exc:
            self._set_status(f"Failed to reload ({exc})")
            return
        if row.id:
            self._claim_session_tab(row.id, tab.id)
        # Same ordering as _open_saved: refresh live so the freshly-
        # created tab id lands in self._live before the rebuild fires,
        # otherwise the session-pass reaper would see the just-claimed
        # tab_id missing from live_ids and silently drop the claim.
        self._refresh_live()
        self._mark_active(row.url, tab.id)
        self._set_status("Reloaded Tab")

    def action_rename_saved(self) -> None:
        # Re-entering rename during rename would reset the buffer to the
        # row's stored title — so if the user has typed `r` as a normal
        # char mid-edit, the binding leak mustn't overwrite their work.
        if self._in_modal_state():
            return
        if self._in_help_mode or self._in_search_mode:
            return
        # Four cursor targets: Workspace row → workspace rename; a
        # saved/live row leaf → tab rename; a _GroupMarker header →
        # group rename; anything else → no-op. Group rename is blocked
        # on Essentials (special-cased upstream).
        tree = self.query_one("#tree", Tree)
        node = tree.cursor_node
        if node is not None and isinstance(node.data, _WorkspaceMarker):
            current_name = self._current_workspace_name()
            if not current_name or not self._current_workspace:
                return
            self._rename_workspace_id = self._current_workspace
            self._rename_buffer = current_name
            self._rename_cursor = len(current_name)
            self._cursor_on = True
            self._rebuild_tree()
            return
        if node is not None and isinstance(node.data, _GroupMarker):
            # The group name is the dict key in _saved_nodes that maps
            # to this header — find it by identity since labels carry
            # styling and the count suffix.
            group_name: Optional[str] = None
            for name, gnode in self._saved_nodes.items():
                if gnode is node:
                    group_name = name
                    break
            if group_name is None or group_name == ESSENTIALS_GROUP:
                return
            self._rename_group = group_name
            self._rename_buffer = group_name
            self._rename_cursor = len(group_name)
            self._cursor_on = True
            self._rebuild_tree()
            return
        row = self._selected_row()
        if row is None:
            return
        # Both saved and live rows enter rename mode here. _commit_rename_url
        # routes the saved title (persistent) vs. _live_titles override
        # (session-only) based on row.kind at commit time. The current
        # display title — including any active live override — seeds the
        # buffer so editing picks up where the previous rename left off.
        if row.kind == "live":
            current_title = self._live_titles.get(row.tab_id, row.title)
        else:
            current_title = row.title
        self._rename_url = row.url
        self._rename_kind = row.kind
        # Live rows: pin to chromium tab_id so multiple tabs sharing a
        # URL don't all render the edit field. Saved rows: pin to
        # SavedTab.id (stable across renames / URL edits / group moves),
        # since URL is no longer unique among saved rows.
        self._rename_tab_id = row.tab_id if row.kind == "live" else None
        self._rename_saved_id = row.id if row.kind == "saved" else None
        self._rename_buffer = current_title
        # Start the insertion cursor at the end of the title — matches the
        # natural "append-first" edit flow (most common case: user wants to
        # tweak or replace the trailing portion). Home/Ctrl+A jumps to the
        # start when they'd rather edit from the front.
        self._rename_cursor = len(current_title)
        self._cursor_on = True
        # Full rebuild (not just _invalidate) on entry so the edit-mode
        # label lands on the row immediately. _invalidate is enough for
        # subsequent per-keystroke repaints since only the one row's
        # label text changes.
        self._rebuild_tree()

    def _in_any_edit_mode(self) -> bool:
        """True when the shared rename buffer is owned by some edit
        flow — saved-tab rename, live-tab session rename, group rename,
        URL edit, new-group preview, new-workspace preview, or workspace
        rename. Used by on_key to gate the buffer-edit branch and by
        render_label to dispatch the right edit visual."""
        return (
            self._rename_url is not None
            or self._rename_group is not None
            or self._url_edit_url is not None
            or self._pending_new_group_row is not None
            or self._pending_new_workspace
            or self._rename_workspace_id is not None
        )

    def _in_modal_state(self) -> bool:
        """True when any modal state owns the user's input — edit mode,
        the save-to-existing picker, the workspace switcher, a pending
        destructive-action confirm prompt, or move/reorder mode. Used
        by every action handler to bail out cleanly so a stray binding
        can't fire on top of an active picker / edit / move. Help and
        search modes are independent states with their own guards
        (callers AND on these too). j/k explicitly bypass this gate
        when _in_move_mode is set so they can drive the reorder."""
        return (
            self._in_any_edit_mode()
            or self._save_picker_row is not None
            or self._workspace_picker_index is not None
            or self._pending_confirm is not None
            or self._in_move_mode
        )

    def _edit_repaint(self) -> None:
        """Called after any edit-buffer or cursor change. Resets the blink
        phase to on (so the cursor is visible right after the keystroke) and
        invalidates the tree so render_label repaints the row."""
        self._cursor_on = True
        self.query_one("#tree", FolderTree)._invalidate()

    def _commit_edit(self) -> None:
        """Dispatch Enter-to-commit to the right handler based on which
        edit mode is active. At most one is set (mutually exclusive)."""
        if self._rename_url is not None:
            self._commit_rename_url()
        elif self._rename_group is not None:
            self._commit_rename_group()
        elif self._url_edit_url is not None:
            self._commit_edit_url()
        elif self._pending_new_group_row is not None:
            self._commit_new_group()
        elif self._pending_new_workspace:
            self._commit_new_workspace()
        elif self._rename_workspace_id is not None:
            self._commit_rename_workspace()

    def _commit_rename_workspace(self) -> None:
        """Persist the buffered workspace name and exit rename mode.
        No-op cancel on empty buffer, matches the rest of the edit
        family. Tab `workspace` references are unaffected (they point
        at workspace id, not name) so the rebuild is purely cosmetic."""
        target_id = self._rename_workspace_id
        new_name = (self._rename_buffer or "").strip()
        self._rename_workspace_id = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        if not target_id or not new_name:
            self._rebuild_tree()
            self._update_search_tree()
            return
        if store.rename_workspace(target_id, new_name):
            self._workspaces = store.load_workspaces()
            self._set_status("Renamed Workspace")
        self._rebuild_tree()
        self._update_search_tree()

    def _commit_rename_url(self) -> None:
        """Persist the buffered title and exit rename mode. Saved rows
        write to store.rename_saved (persistent); live rows write to
        _live_titles[tab_id] (session-only). No-op on empty buffer —
        empty titles would leave the row unlabeled, and cancelling via
        Esc is always available if that's what the user wanted."""
        url = self._rename_url
        if url is None:
            return
        kind = self._rename_kind
        tab_id = self._rename_tab_id
        saved_id = self._rename_saved_id
        new_title = self._rename_buffer.strip()
        self._rename_url = None
        self._rename_kind = None
        self._rename_tab_id = None
        self._rename_saved_id = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        # Arm a 500ms suppression window so the NodeSelected that Tree's
        # own enter-binding posts in parallel with this commit doesn't
        # also activate the tab. The window auto-expires — no callback
        # race with the message pump.
        self._suppress_activate_until = time.monotonic() + 0.5
        if not new_title:
            # Empty buffer = cancel-equivalent. Status bar refresh drops
            # `[rename]` and brings `[preview]` back if that mode was on.
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()
            return
        if kind == "live":
            # Session-only override keyed by chromium tab_id so closing/
            # reopening the same URL doesn't carry the rename forward,
            # and so multiple tabs sharing a URL each get their own
            # override.
            if tab_id:
                self._live_titles[tab_id] = new_title
            self._set_status("Renamed Tab")
            self._rebuild_tree()
            return
        if saved_id and store.rename_saved(saved_id, new_title):
            self._set_status("Renamed Tab")
            self._load_all()
        else:
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()

    def _commit_rename_group(self) -> None:
        """Persist a group rename. Rewrites every member tab's group
        field via store.rename_group. No-op on empty buffer or rename to
        Essentials (special-cased upstream too)."""
        old = self._rename_group
        if old is None:
            return
        new_name = self._rename_buffer.strip()
        self._rename_group = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        self._suppress_activate_until = time.monotonic() + 0.5
        if not new_name or new_name == ESSENTIALS_GROUP or new_name == old:
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()
            return
        # Group names are unique per-workspace — scope the rewrite so
        # a `Reading` in workspace A doesn't drag a `Reading` in
        # workspace B along with it.
        if store.rename_group(old, new_name, self._current_workspace):
            self._set_status("Renamed Group")
            self._load_all()
        else:
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()

    def _commit_edit_url(self) -> None:
        """Persist a URL edit on a saved row. No-op on empty buffer or
        an unchanged URL — Esc is the explicit cancel."""
        old_url = self._url_edit_url
        saved_id = self._url_edit_saved_id
        if old_url is None or not saved_id:
            return
        new_url = self._rename_buffer.strip()
        self._url_edit_url = None
        self._url_edit_saved_id = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        self._suppress_activate_until = time.monotonic() + 0.5
        if not new_url or new_url == old_url:
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()
            return
        # No session-pair migration needed — the dict is keyed by
        # SavedTab.id, which doesn't change under URL edit.
        if store.update_url(saved_id, new_url):
            self._set_status("Updated URL")
            self._load_all()
        else:
            self.query_one("#tree", FolderTree)._invalidate()
            self._update_search_tree()

    def _commit_new_group(self) -> None:
        """Persist the pending new-group save: store.add_saved with the
        typed name as the group. No-op on empty buffer or Essentials —
        Esc is the explicit cancel. _last_save_group is updated so the
        next `s` defaults to the freshly-created group."""
        row = self._pending_new_group_row
        if row is None:
            return
        new_name = self._rename_buffer.strip()
        self._pending_new_group_row = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        self._suppress_activate_until = time.monotonic() + 0.5
        if not new_name or new_name == ESSENTIALS_GROUP:
            self._rebuild_tree()
            return
        try:
            created = store.add_saved(
                title=row.title or row.url,
                url=row.url,
                group=new_name,
                workspace=self._current_workspace,
            )
        except Exception as exc:
            self._set_status(f"Failed to save ({exc})")
            self._rebuild_tree()
            return
        # Saving from a live tab claims that tab for the new saved
        # row's session — without this, the post-startup pair gate
        # below would leave the new row unpaired until the user
        # explicitly opened it.
        if row.kind == "live" and row.tab_id:
            self._claim_session_tab(created.id, row.tab_id)
        self._last_save_group = new_name
        self._set_status("Saved Tab")
        self._load_all()

    def _commit_save_picker(self) -> None:
        """Commit the highlighted group from the save-to-existing picker.
        Live rows → store.add_saved; saved rows → store.move_saved (the
        same picker doubles as a relocate UI). Updates _last_save_group
        so the next `s` defaults here."""
        row = self._save_picker_row
        groups = self._save_picker_groups
        if row is None or not groups:
            self._save_picker_row = None
            self._save_picker_groups = []
            self._update_search_tree()
            return
        group = groups[self._save_picker_index]
        self._save_picker_row = None
        self._save_picker_groups = []
        new_saved_id: str = ""
        try:
            if row.kind == "saved":
                moved = (
                    bool(row.id) and store.move_saved(row.id, group)
                )
                status = f"Moved to {group}" if moved else f"Already in {group}"
            else:
                created = store.add_saved(
                    title=row.title or row.url,
                    url=row.url,
                    group=group,
                    workspace=self._current_workspace,
                )
                new_saved_id = created.id
                status = "Saved Tab"
        except Exception as exc:
            self._set_status(f"Failed to save ({exc})")
            return
        # Saving from a live tab claims that tab for the freshly-created
        # saved row's session so it pairs immediately, even after the
        # post-startup pair gate has closed. Keyed on the new saved id
        # rather than URL so duplicate URLs across rows each get their
        # own pair.
        if row.kind == "live" and row.tab_id and new_saved_id:
            self._claim_session_tab(new_saved_id, row.tab_id)
        self._last_save_group = group
        self._set_status(status)
        self._load_all()

    def _cancel_edit(self) -> None:
        """Top-tier Esc handler — cancels whichever edit/picker mode is
        active and refreshes the bottom bar so the marker drops back to
        `[preview]` (if on) or empty."""
        self._rename_url = None
        self._rename_kind = None
        self._rename_tab_id = None
        self._rename_saved_id = None
        self._rename_group = None
        self._url_edit_url = None
        self._url_edit_saved_id = None
        self._rename_workspace_id = None
        self._pending_new_group_row = None
        self._save_picker_row = None
        self._save_picker_groups = []
        self._workspace_picker_index = None
        self._workspace_picker_items = []
        self._pending_new_workspace = False
        self._pending_confirm = None
        self._rename_buffer = ""
        self._rename_cursor = 0
        self._rebuild_tree()
        self._update_search_tree()

    def action_quit_to_browser(self) -> None:
        # Esc tier 0: move/reorder mode dismisses ahead of the edit
        # picker — _in_modal_state is True for both, but move mode is
        # owned by this method's branch (no rename buffer to cancel),
        # so we pull it out of _cancel_edit's chain explicitly.
        if self._in_move_mode:
            self._exit_move_mode()
            return
        # Esc tier 1: cancel any active edit / picker first. _cancel_edit
        # clears all of the rename / new-group / save-picker state so
        # exactly one tier per Esc lands.
        if self._in_modal_state():
            self._cancel_edit()
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
        # Same fast-kill path Super+W uses; see _fast_close_and_exit.
        _fast_close_and_exit()

    def action_quit(self) -> None:
        # `q` is the quick-exit shortcut: skips the Esc tier ladder
        # (cancel edit → exit search → hide help → park cursor → close)
        # and tears down bm + chromium immediately. Edit / search modes
        # already swallow `q` in on_key (treats it as a printable char or
        # a no-op), so this binding only fires from the normal idle
        # state, where "immediately quit" is what the user wants.
        _fast_close_and_exit()

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
        if self._in_modal_state():
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
        if self._in_modal_state():
            return
        if self._in_help_mode:
            return
        row = self._selected_row()
        if row is None:
            return
        self._peek_row(row)

    def action_toggle_preview(self) -> None:
        if self._in_modal_state():
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
        if self._in_move_mode:
            # Enter commits the reorder — same intent as m/Esc, just a
            # natural "I'm done placing this row" gesture. Checked
            # ahead of _in_modal_state because move mode sets that True.
            self._exit_move_mode()
            return
        if self._in_modal_state():
            # Still in an edit / picker — Enter is owned by that flow.
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

    def on_tree_node_expanded(self, event) -> None:
        self._record_group_collapse(event, collapsed=False)

    def on_tree_node_collapsed(self, event) -> None:
        self._record_group_collapse(event, collapsed=True)

    def _record_group_collapse(self, event, *, collapsed: bool) -> None:
        """Persist a saved-group header's expand/collapse toggle into
        state.json so the next workspace switch / restart restores
        what the user picked. Also drops the group from the filtered
        set: spacebar / click toggles are explicit "binary" intent
        from the user, so any prior filtered state should clear out
        rather than linger and re-assert on the next state change.
        h/l (the three-state cycle) bypasses Textual's expand/collapse
        entirely, so this handler only fires for binary toggles.

        Skips:
        - non-main-tree events (the search overlay tree posts the
          same messages)
        - non-_GroupMarker nodes (live-tab leaves don't expand;
          the Workspace title is a leaf; the pending new-group
          preview header has an empty key in _saved_nodes)
        """
        if event.control is not self.query_one("#tree", Tree):
            return
        if not isinstance(event.node.data, _GroupMarker):
            return
        group_name = next(
            (g for g, n in self._saved_nodes.items() if n is event.node),
            "",
        )
        if not group_name:
            return
        ws_id = self._current_workspace
        collapsed_set = set(store.get_collapsed_groups(ws_id))
        filtered_set = set(store.get_filtered_groups(ws_id))
        if collapsed:
            collapsed_set.add(group_name)
        else:
            collapsed_set.discard(group_name)
        # Binary toggle clears the filtered intent — see docstring.
        if group_name in filtered_set:
            filtered_set.discard(group_name)
            store.set_filtered_groups(ws_id, list(filtered_set))
        store.set_collapsed_groups(ws_id, list(collapsed_set))

    def on_tree_node_highlighted(self, event) -> None:
        # Fires on every cursor-line change within any Tree. We only care
        # about the main tree; the search-tree doesn't have highlightable
        # rows in a meaningful sense.
        #
        # Edit-mode lockdown: during inline edit, Textual's Tree widget
        # has its own up/down arrow bindings that manipulate cursor_line
        # directly, bypassing our App-level gates. If the user hits up/
        # down mid-edit, the cursor would drift to a sibling row (taking
        # the edit UI with it, since render_label keys edit visuals to
        # the cursor row). Snap it back to whichever row owns the edit so
        # keystrokes keep landing where the user expects.
        if self._in_any_edit_mode():
            self._restore_edit_cursor()
            return
        if self._in_preview_mode and not self._in_help_mode:
            self._schedule_preview()

    def _restore_edit_cursor(self) -> None:
        """Move the tree cursor back onto the row that owns the active
        edit. Saved-tab/live-tab rename → matching URL; group rename →
        matching group header; new-group preview → the placeholder
        header. No-op if the target isn't present."""
        tree = self.query_one("#tree", Tree)
        if self._rename_url is not None:
            kind = self._rename_kind
            tab_id = self._rename_tab_id
            saved_id = self._rename_saved_id
            if kind == "live":
                # Loose live leaves only — match on tab_id so multiple
                # tabs sharing a URL don't all attract the cursor.
                for leaf in tree.root.children:
                    if (
                        isinstance(leaf.data, Row)
                        and leaf.data.kind == "live"
                        and leaf.data.tab_id == tab_id
                    ):
                        tree.move_cursor(leaf)
                        return
            elif kind == "saved":
                # Saved Essentials live at root; non-Essentials saved
                # rows live under group nodes. Walk both, matching on
                # SavedTab.id so duplicate URLs don't pull the cursor
                # to a sibling.
                for leaf in tree.root.children:
                    if (
                        isinstance(leaf.data, Row)
                        and leaf.data.kind == "saved"
                        and leaf.data.id == saved_id
                    ):
                        tree.move_cursor(leaf)
                        return
                for gnode in self._saved_nodes.values():
                    for leaf in gnode.children:
                        if (
                            isinstance(leaf.data, Row)
                            and leaf.data.kind == "saved"
                            and leaf.data.id == saved_id
                        ):
                            tree.move_cursor(leaf)
                            return
        if self._rename_group is not None:
            target = self._saved_nodes.get(self._rename_group)
            if target is not None:
                tree.move_cursor(target)
                return
        if self._pending_new_group_row is not None:
            # Pending header is the last group node added to the tree
            # under the placeholder name "" (empty string keys the
            # _saved_nodes entry — see _rebuild_tree).
            target = self._saved_nodes.get("")
            if target is not None:
                tree.move_cursor(target)

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

        Saved-tab peek goes through _activate_saved, which activates
        the row's session tab if paired and otherwise creates a fresh
        chromium tab — peeking many different saved URLs accumulates
        tabs, peeking the same one re-activates its session tab."""
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
        # Claim the chromium tab for the saved row — same session
        # pairing as _open_saved, so peek-then-navigate keeps the
        # saved row paired with whatever URL the tab ends up on.
        if row.kind == "saved" and active_tab_id and row.id:
            self._claim_session_tab(row.id, active_tab_id)
        # Refresh _live BEFORE _mark_active so a tab that
        # _activate_saved just *created* lands in self._live before
        # the next rebuild — same reasoning as _open_saved. Without
        # the reorder, _mark_active's rebuild would reap the session
        # claim because the new tab isn't in the stale live_ids yet,
        # leaving the saved row dim and the new tab as a loose leaf.
        if row.kind == "saved":
            self._refresh_live()
        self._mark_active(row.url, active_tab_id)
        if prev_addr:
            _focus_window(prev_addr)
            self.set_timer(0.08, lambda addr=prev_addr: _focus_window(addr))


def _match(title: str, url: str, needle: str) -> bool:
    if not needle:
        return True
    return needle in title.lower() or needle in url.lower()


def _format_row(row: Row, title: Optional[str] = None) -> str:
    """Render a leaf label as `{glyph}  {title}`. `title` overrides the
    Row's stored title — used by callers to inject a live-tab session
    rename from `BmApp._live_titles[tab_id]` without mutating the Row."""
    glyph = _glyph(row.url)
    return f"{glyph}  {title if title is not None else row.title}"


_HELP_FIRST_ROW = 1  # title at 0, spacer at 1 (cursor floor), key rows at 2+


HELP_LINES = [
    ("j/k", "down / up"),
    ("h/l", "collapse / filter / expand"),
    ("g/G", "top / bottom"),
    ("^D/^U", "half page"),
    ("Enter", "activate tab"),
    ("o", "open tab"),
    ("t", "new tab"),
    ("s", "save to group"),
    ("S", "save to new group"),
    ("e", "edit url"),
    ("d", "delete"),
    ("u", "unload tab"),
    ("y", "yank url"),
    ("Y", "yank saved url"),
    ("m", "move/reorder"),
    ("r", "rename"),
    ("R", "reload saved tab"),
    ("w", "switch workspace"),
    ("W", "new workspace"),
    (";", "next workspace"),
    ("/", "search"),
    ("p", "preview tab"),
    ("P", "preview mode"),
    ("?", "help"),
    ("Esc", "close"),
    ("q", "quit"),
]


def run_tui() -> None:
    import atexit, sys
    # Exit paths — every trigger funnels into the same fast PID-kill +
    # os._exit(0) path (_fast_close_and_exit, defined at module top):
    #   q                       → action_quit
    #   Esc (idle, no modal)    → action_quit_to_browser
    #   Super+W via hyprland    → _watch_hyprland_close (closewindow IPC)
    #   SIGHUP / SIGTERM        → _term
    #   self.exit / sys.exit    → atexit _cleanup (best-effort fallback)
    #
    # On omarchy 3.7 / hyprland 0.54+ / ghostty 1.3+, surface-destroy
    # delivers SIGHUP+SIGTERM repeatedly (~ms apart). The pre-3.7 design
    # had q/Esc do a CDP cookie-flush via launcher.close_chromium (httpx
    # + SSL init + per-tab /json/close + 1.5s PID-exit poll) which made
    # q feel laggy (~5s) even though chromium's UI was already gone, and
    # had _term/_cleanup re-enter the same heavy path under the signal
    # cascade — recursing through ssl.create_default_context until
    # RecursionError pinned bm-py at 100% CPU with chromium still alive.
    #
    # Current design: chromium handles SIGTERM with its normal cookie-
    # persistence + session-write path, so a 1.0s grace before SIGKILL
    # gives the same durability the CDP route did, an order of magnitude
    # faster, and with no signal-race re-entry. The atexit _cleanup is
    # only reached if BmApp.run() returns normally without going through
    # one of the above paths (shouldn't happen in practice).
    def _cleanup() -> None:
        launcher.close_chromium()
        try:
            PID_FILE.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    atexit.register(_cleanup)

    def _term(_signum, _frame):
        # Disable signal-driven re-entry first (subsequent SIGHUP/SIGTERM
        # are ignored), then funnel into the shared fast-close path.
        for sig_to_block in (signal.SIGHUP, signal.SIGTERM):
            try:
                signal.signal(sig_to_block, signal.SIG_IGN)
            except (ValueError, OSError):
                pass
        _fast_close_and_exit()

    for sig in (signal.SIGHUP, signal.SIGTERM):
        try:
            signal.signal(sig, _term)
        except (ValueError, OSError):
            pass
    BmApp().run()
