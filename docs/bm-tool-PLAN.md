# Bookmark Manager — `bm` (Design + Current State)

Arc/Zen-style browser workflow built from komarchy primitives: a single Chromium instance tiled alongside a Textual-based TUI on Hyprland. Saved tabs live in the repo as JSON and sync across machines; live tab control happens over the Chrome DevTools Protocol (CDP). Phase 1 renders a Nerd Font glyph per row (Kitty-graphics favicons are phase 2).

The user-facing command is **`bm`** (bookmark manager). The existing `bm()` bash function (which opens markdown bookmark files in nvim) is renamed to **`bmd`** (bookmark markdown) to free the name.

This doc reflects the **currently shipped** state (migration group 019). Items still open are called out explicitly in the "Phased rollout" section at the end.

## Overview

One Chromium window, one terminal running the `bm` TUI, tiled together by Hyprland. Chromium runs with `--remote-debugging-port=9222` so `bm` can list, activate, open, and close tabs over CDP. `bm` is the only interface for switching tabs; vim-style keybinds inside it handle everything. Saved tabs are stored in `files/config/omarchy/bm/saved-tabs.json` in the repo so they travel between machines through the normal komarchy migration flow.

## Architecture

```
┌────────────────────────── Hyprland workspace ──────────────────────────┐
│                                                                        │
│  ┌──────────────┐  ┌──────────────────────────────────────────────┐    │
│  │  Ghostty     │  │                                              │    │
│  │  + Textual   │──┤            Chromium                          │    │
│  │     bm       │  │   --remote-debugging-port=9222               │    │
│  │              │  │   --user-data-dir=~/.config/.../profile      │    │
│  │  (CDP        │  │                                              │    │
│  │   client)    │──▶  CDP HTTP API on localhost:9222              │    │
│  └──────────────┘  └──────────────────────────────────────────────┘    │
│       ▲                                                                │
│       │                                                                │
│       └── launched together by the `bm` entry script                   │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

The launcher starts chromium in the background, waits for CDP, then runs the TUI inline in the calling terminal via `exec`. **The two processes are paired** — closing one closes the other:

- `q` / `Esc` in the TUI → `launcher.close_chromium()` runs, then the TUI exits.
- TUI exit via any other path (sys.exit, SIGHUP when the terminal dies, SIGTERM) → `atexit` + signal handlers run `launcher.close_chromium()`.
- Chromium closed by the user (CDP stops responding) → `_refresh_live` sees CDP go down and calls `App.exit()`. The CDP-up/down probe runs on every 300ms tick regardless of mode — only the *tree rebuild* is suppressed in help/search (to avoid clobbering the help screen or an active filter), so closing chromium from any mode tears bm down within the refresh window.

`close_chromium()` drives chromium's normal clean-exit path by closing every tab over CDP (the same path File → Quit uses). This flushes session cookies to disk — `pkill -TERM` alone does **not**, which was silently dropping auth for sites like `portal.azure.com`. `pkill` runs as a fallback only if CDP doesn't shut down within ~2s.

When launched from a terminal, after chromium comes up the launcher also shrinks the terminal to `$BM_SIDEBAR_WIDTH` (default 300 px) via `hyprctl dispatch resizeactive` so chromium gets most of the screen.

## Session cookie preservation

Chromium's session (non-persistent) cookies are required for auth on several sites we care about (e.g. `portal.azure.com`). The naive flow — launch chromium fresh, close it hard on exit — drops them. The shipped workaround on every launch:

1. **`clear_crash_marker`** — before spawning, rewrite `Default/Preferences` so `profile.exit_type = "Normal"`, `profile.exited_cleanly = true`, and `session.restore_on_startup = 1`. Suppresses the "Chrome didn't shut down correctly" bubble and tells chromium to restore the previous session.
2. **Launch with `--restore-last-session --disable-session-crashed-bubble`** — chromium restores every tab from the previous session, which rehydrates the in-memory cookie jar.
3. **`clean_tabs`** — immediately after CDP comes up, open a fresh `about:blank` and close every restored tab. The user sees a clean browser even though chromium technically restored the prior session.
4. **Clean exit via CDP** — `close_chromium()` closes each tab over CDP instead of SIGTERM, so chromium's normal shutdown path flushes session cookies to disk for the next launch.

This flow is duplicated in both the bash launcher (`files/local/bin/bm`) and the Python side (`bm/launcher.py`) — the Python version runs when `ensure_up()` self-heals after chromium was closed mid-session.

## `bm` CLI shape

Single entry point with subcommands, following the existing `bm ko` / `bm rpc` pattern:

| Invocation | What it does |
|---|---|
| `bm` | Ensure chromium (with CDP) is running, then run the TUI inline in the current terminal. Shrinks the terminal to the sidebar width if it started chromium. Exits when the TUI exits. |
| `bm focus` | If a bm TUI is already running somewhere, focus its hyprland window; else spawn a dedicated ghostty with `bm.conf` and run `bm` inside. Meant for hyprland keybinds where there's no parent terminal. |
| `bm open <url>` | Open-or-switch: if URL is already an open tab, activate it; otherwise open it in a new tab. Used by Hyprland keybinds and scripts. |
| `bm save [--group <name>]` | Save the tab currently focused in chromium to `saved-tabs.json` (default group: `Unsorted`). Distinct from the TUI's `s`, which saves the *highlighted* row — the CLI has no cursor, so it follows chromium's active tab. |
| `bm list` | Print saved tabs as JSON (scripting hook) |
| `bm rm <url>` | Remove a saved tab by URL |
| `bm next` | Signal the running bm TUI to step its cursor down one row and activate. Mirrors internal `j`+Enter so the external cycle walks the same tree the user sees — Essentials, Saved rows, then loose live leaves, skipping Workspace and group headers. Bound to Hyprland's Super+Alt+J. Silent no-op when the TUI isn't running. |
| `bm prev` | Same as `bm next` but `k`+Enter (cursor up). Bound to Super+Alt+K. |

The Textual TUI and the subcommands both drive the same Python module internally — no duplicated logic. Most CLI subcommands go through `launcher.ensure_up()`, so if chromium was closed between invocations they transparently respawn it (with the session-restore flow above) before running. The exception is `bm next` / `bm prev`: those don't talk to chromium at all — they `os.kill(pid, SIGUSR1/2)` the running bm TUI (PID read from `~/.config/bm/bm.pid`) and let the TUI handle motion and activation in-process. Silent no-op when the TUI isn't running (PID file missing or points to a dead process). Since bm+chromium are paired via the launcher, "TUI gone" also means chromium is gone, so there's nothing meaningful to cycle.

## Components

| Path | Role |
|---|---|
| `files/local/bin/bm` | Entry point — runs TUI inline (no args) or handles subcommands (`focus`, `open`, `save`, `list`, `rm`) |
| `files/local/share/bm/` | Python package (pyproject.toml + `bm/` module) |
| `files/config/omarchy/bm/saved-tabs.json` | Git-tracked saved-tab list, shared across machines |
| `~/.config/bm/state.json` | Local UI state placeholder (currently no keys written — the old cycle bookkeeping was obsoleted by the signal-based external cycle); not in git |
| `~/.config/bm/bm.pid` | PID of the running bm TUI — read by `bm next`/`bm prev` to deliver SIGUSR1/SIGUSR2; not in git |
| `~/.cache/bm/favicons/{domain}.png` | Favicon cache, not in git |
| `files/config/ghostty/bm.conf` | Dedicated Ghostty config for the `bm` window (transparency, no decoration, edge-to-edge) |
| `~/.config/hypr/bindings.conf` | Patched with Super+Alt+hjkl leader block (focus bm / next tab / prev tab / focus chromium) |
| `~/.config/hypr/looknfeel.conf` | Patched with `no_shadow on` windowrule for `class:com.ko.bm` |

## Chrome DevTools Protocol

Chromium launched with `--remote-debugging-port=9222` exposes an HTTP API the TUI drives directly. Four calls cover everything `bm` needs:

```bash
# List all open tabs (returns JSON with id, title, url, faviconUrl)
curl -s localhost:9222/json/list

# Activate an existing tab
curl -sX PUT localhost:9222/json/activate/<tab_id>

# Open a new tab with URL
curl -sX PUT "localhost:9222/json/new?https://example.com"

# Close a tab
curl -sX PUT localhost:9222/json/close/<tab_id>
```

The Python TUI uses `httpx` to call these same endpoints. Raising the Chromium window when activating from `bm` uses `hyprctl dispatch focuswindow class:Chromium`.

## Textual TUI Layout

Two stacked Textual `Tree` widgets inside a single `Vertical`:

- **`#tree`** — main list (`height: 1fr`). A custom `FolderTree(Tree)` subclass replaces Textual's default `▶`/`▼` chevrons with Nerd-Font folder glyphs (closed `` / open ``) and renders those glyphs *inline in `render_label`* (ICON_NODE is set empty) so the glyph and label share a single style and can be recolored together. Top-level rows, in render order:
  - **Workspace** — title row (accent + bold, same style as the help screen's "Keybindings" title) that anchors the current saved-tab workspace. Placeholder for workspace-level actions; today it has no children.
  - **Essentials** — 3 fixed rows (ChatGPT, Claude AI, Google) in `color6` cyan. Inline icons + labels at column 0, one leaf per row (not branches — we don't want the folder chevron on them).
  - **Saved: `<group>` (N)** — one branch per saved-tab group (accent + bold header). Saved rows render *before* loose live tabs so bookmarked content reads first and open-but-unsaved tabs collect below.
  - **Divider** — a single dim horizontal rule (U+2500 at ~0.1 foreground opacity) painted across the tree width, separating saved folders from loose live leaves. Only rendered when there are loose live leaves to show. Styled as a ghost rule because the other section breaks use braille-blank spacers — this boundary benefits from a visible cue since it separates two different *kinds* of rows (folders above, loose leaves below).
  - **Loose live leaves** — every live chromium tab whose URL isn't already represented by a saved row, rendered as top-level leaves (same shape as Essentials: no group header, each tab on its own row at the root). See "URL-based saved↔live pairing" below for how duplicates are handled.

  This is the only focusable widget. Tree `guide_depth` is `1` (minimum viable indent) and the `├─ └─ │` guide lines are hidden via CSS (`.tree--guides` color set transparent) so the tree reads as a clean column.
- **`#search-tree`** — single-row leaf at the bottom (`height: 1`). Multiplexed across three primary uses with priority: **active search > ephemeral status > committed filter > empty**, plus a **mode-marker suffix** (`[rename]` or `[preview]`) that rides alongside whichever primary is showing, **except** during active search (would fight the blinking prompt) and during an ephemeral status message (the tag would push the message around; `_blink_cursor` re-renders when the status times out and the suffix comes back).
  - Active search: `/foo█` (blinking cursor while typing)
  - Ephemeral status: transient notification like `Saved Tab`, `Removed Tab`, `Already saved`, or `Failed to activate (…)`, rendered at **0.65 foreground opacity** (readable but clearly non-focal, via `_faded_fg(0.65)`) and auto-cleared after `STATUS_DURATION` (3s). Kept deliberately short — no title embedded in the message, since the cursor already shows which row was acted on.
  - Committed filter: `/foo` (no cursor) once the user hits enter on a search
  - Mode-marker suffix: `[rename]` or `[preview]` rendered at **0.35 foreground opacity** via `_faded_fg(0.35)` — noticeably dimmer than the 0.65 status tier, because it's a persistent mode marker that should sit quietly at the edge rather than compete with transient messages on the left. Exactly one marker shows at a time, with `[rename]` taking priority over `[preview]` (rename is a modal edit; preview is passive). Both use the same dim tier so they read as the same class of indicator. **Right-aligned** at the opposite end of the row; primary content stays left-aligned with the one-cell braille-blank inset, and braille-blank padding between them is computed from `search_tree.size.width` to push the suffix to the edge. `on_resize` re-renders so the alignment tracks terminal-width changes. On the one call that flips `display:False→True` the widget hasn't been laid out yet (`size.width == 0`); that case falls back to a minimum gap and schedules `call_after_refresh(self._update_search_tree)` so the suffix snaps to the right edge on the next paint instead of visibly sliding over from the left. Exiting rename mode restores `[preview]` automatically — `_in_preview_mode` is independent state, so once `_rename_url` clears, the next `_update_search_tree` call naturally falls through to the preview branch.
  - Hidden entirely when none of the above applies — the main tree fills the viewport

```
╭─ bm ──────────────────────────────────────────╮
│ Workspace                                     │  ← accent + bold (title tier)
│                                               │
│  ChatGPT                                      │  ← color6 cyan (essentials)
│  Claude AI                                    │
│  Google                                       │
│                                               │
│  Saved: Work (5)                              │  ← accent + bold (group header)
│   [] Azure Portal                             │
│   [] Jira – TEAM board                        │  ← color11 yellow = active tab
│   ...                                         │
│  Saved: Personal (8)                          │
│  Saved: Reading (12)                          │
│ ─────────────────────────────────────────── │  ← dim ghost divider (loose leaves below)
│  [] GitHub – claude-code/issues               │
│  [] Hacker News                               │
├───────────────────────────────────────────────┤
│ /github█                                      │  ← #search-tree (search / status / filter)
╰───────────────────────────────────────────────╯
```

Each row shows the favicon glyph (phase 1) or Kitty-graphics image (phase 2), followed by the title. Groups are collapsible sections in the saved-tabs half.

**Visual hierarchy.** Rows are tiered by color/weight so the structure reads at a glance:

| Tier | Color | Weight | Rows |
|---|---|---|---|
| Title | `accent` | bold | Workspace, Saved: `<group>` |
| Essentials | `color6` (secondary / cyan) | regular | ChatGPT, Claude AI, Google |
| Active tab | `color11` (bright yellow) | regular | the row whose chromium `tab_id` matches the currently-active browser tab (updated by Enter/o/p/P, the external Super+Alt+J/K cycle, *and* manual tab switches inside chromium — see "Active-tab highlight" below) |
| Default | `foreground` | regular | all other tab rows |

**Sentinel markers** on `TreeNode.data` let `FolderTree.render_label` distinguish row types without string-matching labels: `_WorkspaceMarker`, `_EssentialsMarker`, `_GroupMarker`, `_SpacerMarker` (braille-blank separator rows), plus the pre-existing `_SearchMarker` and `Row` dataclass for tab leaves.

**Per-row colors always re-applied in `render_label`.** Textual's `Tree.render_label` computes a `style` for each line that includes the widget's default color (typically `$text`) and stylizes the label copy with it via `super().render_label`. That overrides per-label color spans baked at `Text()` creation time — so labels like `Text("Workspace", style=Style(color=accent, bold=True))` would wash out to `$text`. `FolderTree.render_label` therefore resolves the intended color + bold per marker type and re-stylizes on every call, regardless of cursor state. Hover dim is a blended variant of the same per-row color (see below), so a parked cursor shows the full, non-dimmed color; a cursor-visible row shows the dim blend. Non-selected tab leaves (unstyled plain-string labels) get `foreground` explicitly for the same reason — Textual's base-style `$text` can differ from the omarchy theme's `foreground` (e.g. a "cream" omarchy foreground becoming pure white).

**Hover dim.** On the cursor row, `render_label` blends the row's own color toward the theme background via `FolderTree.HOVER_DIM_FACTOR` (`0.5` — halfway to bg). This preserves each row's hue (Workspace accent, Essentials cyan, etc.) instead of repainting to `$accent` which clashed with rows that intentionally use a different palette. ANSI `dim` is avoided because ghostty renders it as grayscale rather than a per-hue fade. Help-screen rows (`data=None`, multi-span labels with colored key + plain description) get a special cursor-only fallback: when parked they keep their per-span colors, but on the cursor row the whole label flattens to the dim foreground so it reads as "selected" without needing per-row colors.

**Esc-to-park cursor.** Esc has a four-tier hierarchy: first it cancels an in-progress inline rename (see "Inline rename" below) if active; next it exits `/search` if active; next it closes the help screen if visible; next it *parks the cursor* (hides the hover dim while preserving `cursor_line`); only then does it close bm + chromium. Park state rides on a `FolderTree.cursor_active: reactive[bool]` attribute — `render_label`'s `is_cursor` check gates on it, and the watcher calls `Tree._invalidate()` to clear the per-line render cache (a plain app-level flag wouldn't invalidate, so stale dim would linger up to 3s until `_refresh_live`'s rebuild cleared the cache as a side effect). Motion actions (`j/k/↑/↓/g/G/Ctrl+D/U/h/l`) call `_activate_cursor()` to flip it back on; action keys (`Enter`/`o`/`s`/`d`/`r`/`p`/`P`) deliberately do not — acting on a parked cursor still works against the last `cursor_line`, with no purposeless flash before the action lands.

**Inline rename.** `r` on a saved row enters an in-place edit state rather than pushing a modal. `BmApp._rename_url` holds the target row's URL, `_rename_buffer` holds the in-progress title, and `_rename_cursor` is a 0..len(buffer) insertion index. `FolderTree.render_label` keys off `_rename_url` and, for the matching saved row, returns a custom multi-span label — accent-colored glyph + head, the char at the cursor position rendered with inverted colors (accent background, theme background as foreground) for the block-cursor look, then accent-colored tail — bypassing the rest of the styling flow (hover-dim, active-tab highlight) so edit mode owns that row's appearance. Inverting a char rather than inserting a separate block character is what makes the cursor read as a terminal-style cursor "on" a character instead of a space wedged between characters. At end-of-buffer the inverted cell falls back to a phantom space so the cursor still has a 1-cell presence. The cursor block reuses `_cursor_on` and the existing 0.5s blink interval; during rename mode the blink tick calls `tree._invalidate()` instead of `_update_search_tree` so the row repaints without touching the search-tree multiplexer. `on_key` swallows every key except Esc while `_rename_url` is set: Enter commits (`store.rename_saved` + `Renamed Tab` status), Backspace / Delete remove the char before / at the cursor, Left / Right / Home / End (plus Ctrl+A / Ctrl+E) move the cursor, printable chars insert at the cursor, and motion / ctrl combos are consumed silently so stray presses can't scroll away or activate a different row mid-edit. Esc falls through to `action_quit_to_browser`, which has a rename-cancel tier above the existing search/help/park/close tiers. `_refresh_live` also gates on `_rename_url is None` alongside `_in_search_mode` / `_in_help_mode` — a 300ms tree rebuild during typing would wipe the edit state. Empty-buffer commits (`Enter` on a blank title) are a no-op cancel rather than persisting an empty string.

**Rename binding-leak gates.** In this Textual version, `event.stop()` in `on_key` does not reliably prevent App-level `Binding` dispatch from firing in parallel — observed first with arrow keys (Left collapsing the parent group under the rename row), then again when the user typed `r` mid-edit and `Binding("r", "rename_saved")` re-entered rename mode, resetting the buffer to the row's stored title on top of the user's keystroke. Mitigation: every motion action *and* every action bound to a printable key (`action_rename_saved`, `action_save_selected`, `action_delete_saved`, `action_open_saved`, `action_focus_search`, `action_peek`, `action_toggle_preview`, `action_show_help`, `action_activate`, plus the collapse/expand/cursor/jump/half-page family) short-circuits with `if self._rename_url is not None: return` at the top. The printable-char insert in `on_key` still runs, so the keystroke lands in the buffer as intended.

**Rename commit-Enter suppression.** Pressing Enter to commit a rename hits two paths: (1) our `on_key` sees `enter`, calls `_commit_rename`, which clears `_rename_url` and rebuilds the tree; (2) Textual's `Tree` posts a `NodeSelected` message from its own enter-binding. The NodeSelected is processed *after* on_key returns, by which point `_rename_url` is already cleared, so the existing mode gate in `on_tree_node_selected` misses and the tab activates right on top of the commit — user intent ("save") turns into "save AND open." Fix: a **timestamp window** `_suppress_activate_until`. `_commit_rename` sets it to `time.monotonic() + 0.5`, and `on_tree_node_selected` skips `action_activate` while `time.monotonic()` is below that deadline. An earlier attempt used a boolean flag cleared via `call_after_refresh` as a safety net; that clear fires *before* the queued NodeSelected is processed (refresh callbacks drain ahead of the message pump in this version), which cleared the flag too eagerly and let the activation leak through. The timestamp approach doesn't care about callback ordering — it auto-expires purely on wall-clock time, so the user's Enter-to-commit lands as "save only" regardless of when NodeSelected happens to fire. 500ms is large enough to swallow the one bubbled NodeSelected and short enough that the user can't realistically click another row within the window.

**Rename cursor lockdown.** Textual's `Tree` *also* has its own `up`/`down` key bindings that manipulate `cursor_line` *directly* — even the App-level action gates don't catch that path. Pressing up/down would drift the cursor to a neighboring row and take the inline edit UI with it (since `render_label` keys the edit field off the cursor row's URL). `on_tree_node_highlighted` watches for this: while `_rename_url` is set, any highlight event landing on a row whose URL doesn't match the rename target triggers `_restore_rename_cursor`, which walks `_saved_nodes` and `tree.move_cursor`s back onto the row being edited. Net effect: up/down arrows are a visible no-op during rename; the edit field stays anchored.

**Rename viewport scroll.** The sidebar is narrow (~25 cells at the 300px default) and saved rows are nested one level under a group header, so typical titles overflow the visible row width. `render_label` computes `avail = size.width − 6` (overhead: indent + glyph + two spaces + safety) and, when `len(head) + 1 + len(tail)` exceeds `avail`, windows the buffer around `_rename_cursor`: if one side fits in its `half` budget the other side gets the leftover room; otherwise both sides clip to `half` cells each. The clipped boundary char on each truncated side is replaced with `…` so the truncation is visually obvious. Net effect: the cursor stays on-screen regardless of where the user moves it, and arrow-key navigation through a long title scrolls the visible window naturally rather than looking like "nothing happened." Tree CSS also sets `overflow-x: hidden` so a wide label can't push the whole ScrollView's virtual width and horizontally scroll the entire sidebar when the user presses arrows.

**Active-tab highlight.** `BmApp._active_tab_id` tracks the chromium tab id of the currently-active tab; `_active_url` mirrors it for non-render-path uses. Both update via a single `_mark_active(url, tab_id)` helper called from every activation path (`action_activate`, `_open_saved`, `_peek_row`). `render_label` paints any `Row` leaf whose `tab_id` equals `_active_tab_id` with `color11` — for live leaves that's their own chromium id, for saved rows it's the *paired* chromium id assigned in `_rebuild_tree` (see "URL-based saved↔live pairing"). Matching on `tab_id` rather than `url` is deliberate: when the user has multiple chromium tabs on the same URL (three Yahoo tabs, say), URL matching would light up all three rows — `tab_id` isolates the one chromium is actually showing. Hover on the active row *keeps* the full `color11` (no dim blend) because `dim = is_cursor and not is_selected` in `render_label` — the "you are here" cue is the one row that must stay vibrant under the cursor.

**URL-based saved↔live pairing.** During `_rebuild_tree`, each saved URL absorbs the *first* live tab it matches (walking `self._live`, which is first-seen stable order). That tab's chromium id is stored on the saved `Row` as its `tab_id`, and added to a `consumed_tab_ids` set so the live pass below excludes it. Remaining live tabs render as loose leaves below the divider. Net effect: one saved row per saved URL, and any *additional* chromium tabs on the same URL still show as loose leaves so the user can reach them. Activation paths that know a specific `tab_id` (both live rows and saved rows after pairing) call `cdp.activate(tab_id)` directly via the `_activate_saved` helper — avoiding the MRU-order mismatch that `open_or_switch`'s URL lookup would otherwise introduce, where CDP's `cdp.list_tabs()` returns tabs in browser MRU order (so the "first URL match" there can be a different tab than bm's first-seen pair). For saved rows with no paired live tab (URL not open), `_activate_saved` falls back to `open_or_switch` which creates a new tab.

**Follow chromium's focused tab.** The user can switch tabs inside chromium (click a tab, Ctrl+Tab) without bm observing the event. `_refresh_live` closes that gap: chromium's `/json/list` returns pages in MRU order, so the first entry is whichever tab chromium is currently showing. Each refresh tick (every 300ms) compares `raw_tabs[0].id` to `self._active_tab_id`; on divergence, bm updates both `_active_url` and `_active_tab_id` to match, and the highlight follows within one tick.

## Keybinds (inside the TUI)

All tab-navigation logic lives inside `bm` — the global keybind just gets you there.

| Key | Action |
|---|---|
| `j` / `k` (or `↓` / `↑`, or `Shift+j` / `Shift+k` while searching) | Move down/up through tab list. `_skip_spacers(tree, direction)` runs after every motion action to step past `_SpacerMarker` leaves (the two braille-blank separators around Essentials), so the cursor never parks on a visually empty row. In help mode the helper short-circuits — the row at `_HELP_FIRST_ROW` is an intentional cursor-floor spacer owned by `_clamp_help_cursor`. |
| `h` / `l` (or `←` / `→`, or `Shift+h` / `Shift+l` while searching) | Collapse/expand group, or switch section (Open ↔ Saved) |
| `g` / `G` (or `Home` / `End`) | Jump to top / bottom |
| `Ctrl+d` / `Ctrl+u` (or `PgDn` / `PgUp`) | Half page down / up |
| `⏎` | Activate selected tab (also raises chromium, returns focus to browser) |
| `o` | Open-or-switch the selected row (works on live and saved rows — saved rows find-or-create a chromium tab at that URL) |
| `s` | Save the selected row to `saved-tabs.json` (no-op status "Already saved" if the cursor is already on a saved row) |
| `d` | Delete selected saved tab |
| `r` | Rename selected saved tab — edits **inline on the row** (glyph + buffer with a terminal-style inverted block cursor in accent color), not in a modal. `[rename]` shows in the status bar at the same dim tier as `[preview]`, taking priority if preview mode was also on (restored automatically on exit). Enter commits (shows `Renamed Tab` status), Esc cancels. Inside the edit field: Left/Right move the cursor by one; Home/Ctrl+A and End/Ctrl+E jump to the ends; Backspace deletes the char before the cursor; Delete removes the char at the cursor; printable keys insert at the cursor. Other keys (motion bindings, ctrl combos, arrow keys that would otherwise scroll the tree) are consumed silently so stray presses can't scroll or activate mid-edit. An empty buffer on Enter is a no-op (cancel-equivalent) — blanking a title would leave the row unlabeled, so we require Esc as the explicit path. Long titles overflow the sidebar width; the visible window scrolls around the cursor with `…` on the clipped side(s). |
| `/` | Filter search (narrows both sections; text appears in the bottom `#search-tree` leaf) |
| `n` / `N` | Next / previous search match |
| `p` | Peek — activate the selected tab in chromium without raising the chromium window (one-shot; keyboard focus stays in bm) |
| `P` | Toggle auto-preview mode — every cursor move auto-peeks. `[preview]` shows in the status line while on |
| `?` | Toggle help — renders a "Keybindings" reference inline in the main tree (see below) |
| `q` or `Esc` | Contextual dismiss, three tiers: (1) in search, clears the filter; (2) in help, closes help; (3) with the cursor visible, parks the cursor (see "Esc-to-park cursor" above); (4) once parked, closes chromium and exits the TUI. `q` behaves the same as `Esc` at every tier. |

### Help screen (`?`)

Tap `?` to swap the tree contents for a keybind reference. Renders **inline in the same Tree** (not a separate widget) so the window's transparency is preserved — a prior Static-based layout painted the area opaque with `$background` regardless of CSS, which is why we stayed in the Tree.

Layout:

- **Title row** `Keybindings` in **bold accent** color.
- **Spacer row** — a single Braille-blank leaf.
- **Key column** right-aligned within a fixed width, padded with **Braille Pattern Blank (U+2800)**. Tree strips leading ASCII/Unicode whitespace from labels but U+2800 isn't classified as whitespace, so the padding survives and the column aligns cleanly.
- **Left margin** — one Braille-blank cell so the whole block has breathing room from the window edge (matches the status line's inset).
- **Key color** = the theme's `color6` (secondary, typically cyan), matching the Essentials row in the main tree for a consistent "command / action" visual. Falls back to `secondary` then `accent` if a theme doesn't expose `color6`. Earlier versions had a per-theme carve-out for osaka-jade; the universal `color6` mapping subsumes that cleanly.

Motion keys (`j/k`, arrows, `g/G`, `Ctrl+d/u`, `h/l`) keep working while help is visible so you can scroll the list. Modification actions (`Enter`, `o`, `s`, `d`, `r`) are short-circuited in help mode. `?` toggles out; `Esc`/`q` also closes the TUI as usual.

**Cursor floor in help mode.** Opening help parks the cursor on the blank spacer row (tree index 1), not the title. `action_cursor_up`, `action_half_page_up`, and `action_jump_top` clamp to that same floor so `k` / `Ctrl+U` / `g` can never land on row 0 (the `Keybindings` title). Row 1 is a braille-blank leaf — there's no visible text for the hover-dim to color — so help opens looking "unselected" and the title stays decorative.

## Peek (`p`) and auto-preview mode (`P`)

Two keys, one underlying primitive. `p` fires a **one-shot peek**: activate the selected tab in chromium while keeping keyboard focus on the bm terminal. `P` toggles **auto-preview mode**, where every cursor motion auto-peeks — you can scroll with `j/k` and watch chromium redraw beside you. A faded `[preview]` tag appears in the `#search-tree` status row while mode is on, and persists alongside a committed filter.

Both paths funnel through one helper — `_peek_row(row)` — so peek and auto-preview share the activate-and-restore-focus dance below.

**Two row kinds, two behaviors.**

- **Live tab** → `cdp.activate(tab_id)`. Flips chromium's active tab.
- **Saved tab** → `actions.open_or_switch(url, raise_window=False)`. Finds an existing tab at that URL and activates it, or opens a new one. The `raise_window` kwarg on `open_or_switch` skips `raise_chromium()` for this path. Peeking many different saved URLs will accumulate tabs in chromium — that's the cost of the feature, not a bug; peeking the same URL repeatedly reuses the tab via `cdp.find_by_url`.

**Focus-theft workaround.** CDP's `/json/activate` (and `Page.bringToFront`) internally call chromium's `BringToFront`, which raises the chromium window on hyprland — there is no CDP flag to suppress it, so skipping our own `raise_chromium()` isn't enough on its own. `_peek_row` therefore:

1. captures the currently-focused window via `hyprctl activewindow -j` (that's bm, since the user just pressed a key in it),
2. calls the CDP activate,
3. reasserts focus on the captured address via `hyprctl dispatch focuswindow address:<addr>` immediately,
4. schedules one delayed retry at 80 ms — chromium's window-activation event can arrive asynchronously, after our sync refocus lands, and without this retry focus occasionally flips back to chromium.

The `_active_window_address` / `_focus_window` helpers in `bm/tui.py` are tiny hyprctl wrappers; they no-op cleanly if `hyprctl` isn't on PATH (non-hyprland use).

**Debouncing (auto-preview only).** Cursor moves schedule `_do_preview` on a 100ms timer (`_preview_debounce`). Mashing `j` coalesces into a single CDP call per pause instead of flickering chromium through every intermediate tab. Each new motion cancels the pending timer and starts a fresh one, so the preview always reflects where the cursor actually stopped. One-shot `p` bypasses this — it peeks immediately.

**Motion hook.** Auto-preview is driven by Textual's `Tree.NodeHighlighted` event (via `on_tree_node_highlighted`), not by patching each motion action. One handler covers `j/k`, arrows, `g/G`, `Ctrl+d/u`, shift variants, and any future motion binding — whatever moves the cursor fires the event.

**Suspended in help mode.** When help is visible the rows are text, not tabs (`_selected_row()` returns `None`), and `_do_preview` short-circuits. The preview-mode flag is preserved across help, so closing help resumes previewing.


## Favicons

**Phase 1 (shipped):** every row renders a Nerd Font globe glyph — no network calls on the render path. The earlier prototype that fetched favicons synchronously on every row/refresh added up to 20s of blocking per first paint, so the fetch was removed entirely.

**Phase 2 (planned):** background worker fetches and caches favicon PNGs, then the TUI paints them via the Kitty graphics protocol (Ghostty supports it). Fetch pattern to reuse:

- **Live tabs** — CDP's `/json/list` response already includes `faviconUrl` per tab.
- **Saved tabs** — reuse `files/local/bin/appgroup-create-webapp:47-50`: try `https://{domain}/apple-touch-icon.png`, fall back to `https://www.google.com/s2/favicons?domain={domain}&sz=128`.

**Caching:** `~/.cache/bm/favicons/{domain}.png`. Never git-tracked — trivially reconstructed. Already wired up in `bm.favicon`; just not called from the render path yet.

**Compact mode (Phase 2, unlocked by Kitty graphics).** Once PNG favicons are painted via the Kitty graphics protocol, a user-driven compact mode becomes viable: one keybind (probably `ctrl+v` — scoped inside bm, doesn't conflict with ghostty's `ctrl+shift+v` paste) toggles between a normal view (1-cell-tall rows, icon + title inline) and a compact view (3-cell-tall rows, single large icon per row, no text). Kitty graphics supports `c=<cols>,r=<rows>` sizing so the same cached PNG renders at either footprint — no font-size toggling, no ghostty coordination, no file writes. All state stays in `BmApp`.

Why this is the right home for the feature (and why we *didn't* ship it in Phase 1):

- **No terminal coordination needed.** The Nerd-Font approach couples icon size to font size, which is a ghostty-wide knob — there's no way to change font size from within a TUI (`set_font_size` only fires via ghostty keybinds; there's no escape sequence or IPC). Kitty graphics decouples icon size from font size entirely.
- **Multi-cell rows need a custom Tree subclass.** Textual's `Tree` assumes 1-cell leaves. Compact mode needs each leaf to occupy 3 cells vertically so the image has room. Either subclass `Tree` to allocate N lines per leaf, or swap the widget (e.g., a custom `OptionList` variant). This is the real implementation work — items 1 and 2 in the fetch/render pipeline below are mostly already scaffolded.
- **Alternative we tried and rejected (dev log, 2026-04-22).** A width-based auto-compact mode in Phase 1 that dropped row labels when `self.size.width < 14` cells worked visually but hit two dead ends: (a) Hyprland 0.54's `minsize` windowrule doesn't exist, so the window can't shrink below ghostty's cell-based floor anyway — icons were visible but with unused empty cells to their right; (b) bigger icons required font-size toggling, which can only be done via two separate ghostty keybinds (no `toggle_font_size` action exists) or a fragile bm.conf-rewrite + `SIGUSR2` reload hack. Revisiting once Kitty graphics makes the icon size a bm-local concern.

## Saved-tab file format

Flat list, `group` as a string per tab. Keeps the schema easy to hand-edit and trivial for any future tool (nvim plugin, scripts, other machines) to read:

```json
{
  "tabs": [
    {
      "title": "GitHub",
      "url": "https://github.com",
      "group": "Work",
      "added": "2026-04-17"
    }
  ]
}
```

## Persistent state split

| Lives in | Git-tracked? | Purpose |
|---|---|---|
| `files/config/omarchy/bm/saved-tabs.json` | Yes | Canonical saved-tab list — the whole point of the feature |
| `~/.config/bm/profile/` | No | Dedicated chromium profile (cookies, saved passwords, site permissions, history). Per-machine, not git-shared, but **preserved across `019` rollback** so the fast dev loop doesn't force re-login / re-block notifications every cycle. Wiped only on `020` rollback. |
| `~/.config/bm/state.json` | No | Local UI state (reserved). No keys are actively written today — the external cycle used to write `tab_cycle_url` / `tab_cycle_tab_id` / `live_order` here, but the signal-based cycle architecture obsoleted those. Kept as the home for future local state (collapsed groups, persisted filter, etc.). Disposable. |
| `~/.config/bm/bm.pid` | No | PID of the running bm TUI, written on mount and removed on shutdown (atexit + SIGHUP/SIGTERM). Read by `bm next`/`bm prev` to find the signal target. Stale PID files are unlinked on send failure. Disposable. |
| `~/.cache/bm/favicons/` | No | Regenerable image cache. Disposable. |

Only canonical, machine-shared data lives in the repo. Of the local-only paths, the chromium profile is stateful user data (auth, permissions) and is preserved across the fast rollback loop; everything else is disposable.

## Hyprland integration

Two patches — a global keybind block and a windowrule for the bm class.

**Global keybinds** (`~/.config/hypr/bindings.conf`, wrapped in `# --- BEGIN/END ko komarchy bm-tool bindings ---` markers so rollback can strip cleanly):

```
bindd = SUPER ALT, H, bm sidebar,    exec, $HOME/.local/bin/bm focus
bindd = SUPER ALT, J, bm next tab,   exec, $HOME/.local/bin/bm next
bindd = SUPER ALT, K, bm prev tab,   exec, $HOME/.local/bin/bm prev
bindd = SUPER ALT, L, focus browser, exec, hyprctl dispatch focuswindow class:chromium
```

Vim-key leader block. `Super+Alt` is chosen because `H/J/K/L` are unbound there at every layer — stock omarchy uses `Super+J/K/L` (single-Super, no Alt) for window-split / show-keybinds / toggle-layout, which stay intact. `Super+Alt+arrows` are *not* free (omarchy uses them for window-to-group movement and resize), so we deliberately bind the vim keys.

`bindd` (not `bind`) — the `d` variant carries a description that shows up in keybind cheatsheets (including `Super+K`, the stock "Show key bindings" popup). Absolute paths are used because hyprland's exec PATH doesn't include `~/.local/bin` in default omarchy setups — the keybinds would otherwise silently fail with "command not found."

**What each bind does:**

- **H — focus bm**: same as the old `Super+B`. Focuses the running bm window via process-ancestry lookup; spawns a new sidebar ghostty if none is running.
- **J / K — cycle every row in bm's tree, without moving focus**: signals the running bm TUI (SIGUSR1 for next, SIGUSR2 for prev) to step its cursor through Essentials → Saved rows → loose live leaves (skipping Workspace, group headers, and spacers), wrapping at edges. Keyboard focus stays on whatever app you're in. Silent no-op when the bm TUI isn't running — bm+chromium are paired via the launcher, so "TUI gone" means "nothing meaningful to cycle."
- **L — focus chromium**: `hyprctl dispatch focuswindow class:chromium`. Symmetric counterpart to H for the two-pane sidebar layout.

**External cycle architecture (signal-based).** Super+Alt+J/K is a **remote trigger for the TUI's internal motion**, not a CLI that reconstructs tree state. The division of labor:

- **TUI side.** On startup, `BmApp.on_mount` writes its PID to `~/.config/bm/bm.pid` and installs asyncio signal handlers for SIGUSR1/SIGUSR2 via `loop.add_signal_handler(...)`. `run_tui`'s atexit + SIGHUP/SIGTERM handlers remove the PID file so the next cycle press doesn't signal a dead process (or, worse, a reused PID). When a signal arrives, `_cycle_step(direction)` runs on the event-loop thread (safe to touch Textual state): it walks `tree.action_cursor_down()` / `_up()` past any `_SpacerMarker` / `_WorkspaceMarker` / `_GroupMarker`, wraps at the tree edges, then activates the resulting row via `_peek_row` — the same path used by `p` and preview mode, so the capture-active-window / reassert-focus dance is inherited for free. Landing on an Essential row moves the cursor but doesn't touch chromium (Essentials have no URLs).
- **CLI side.** `actions.send_cycle_signal(direction)` reads the PID file and `os.kill(pid, SIGUSR1/2)`. That's the entire CLI contribution — no CDP calls, no saved-tab reconstruction, no state writes. Stale PID files (TUI died without cleanup) are detected via `ProcessLookupError` and unlinked so the next press is cheap.

The TUI is the single source of truth for tree ordering and activation. One benefit: the cycle automatically includes whatever the TUI chooses to render (currently Essentials + Saved rows + loose leaves) without the CLI having to model the same structure. Another: no `state.json` bookkeeping — the TUI's in-memory cursor is the cycle anchor.

**Cursor visibility during external cycle.** `_cycle_step` keeps `cursor_active = True` so the hover dim lands on whichever row the cycle stopped at — a visible pointer in the tree as the user steps through from another app. Safe because `render_label` suppresses the dim on active rows (`is_cursor and not is_selected`), so the color11 highlight on the just-activated row paints over the dim immediately.

**Stable live-tab order.** Chromium's `/json/list` returns tabs in MRU order on most builds, so every `cdp.activate` (from preview, external cycle, or Enter) would reshuffle the loose live leaves — the tab you just jumped to would pop to the top, dragging neighbors around. `_stable_sort_live` fixes this by maintaining `self._live_order: list[str]` of tab ids in first-seen order: each refresh drops ids that no longer exist, appends newly-seen ids to the end, then returns `cdp.Tab`s in that order. Only *position* is stabilized — titles and URLs still update live when the user navigates within a tab. The first entry from CDP's raw (MRU-ordered) response is captured *before* sorting and used for the active-tab follow (see "Follow chromium's focused tab"), so MRU-driven reshuffling doesn't contaminate the tree order while still feeding the highlight.

**Diff-guarded refresh.** `_refresh_live` fires every `REFRESH_SECONDS` (300 ms), but the tree only rebuilds when something visible actually changed — a `_tabs_differ` helper compares `(id, url, title)` tuples between old and new `self._live`, and an `active_tab_id` inequality check covers manual chromium tab switches. Most 300 ms ticks are pure polling: two localhost HTTP calls (~2-5 ms total) and zero rendering work. Cost of the faster cadence stays below noise, while active-tab follow / open / close events propagate to the UI in ≤300 ms worst case.

**Cursor survives rebuilds.** When `_rebuild_tree` does fire, `tree.clear()` resets the cursor to line 0 — without preservation, both local j/k navigation and the external-cycle cursor would be thrown away on every rebuild. `_rebuild_tree` therefore captures the cursor's current row `url`/`kind` before clearing, then schedules `_restore_cursor` via `call_after_refresh` to re-move the cursor onto the matching leaf (loose live tabs live at `tree.root.children`; saved tabs nest under `self._saved_nodes[group].children`). The `call_after_refresh` indirection is required: right after `tree.clear()` + `add_leaf`, Textual hasn't laid out the new TreeNodes yet — each leaf's `line` attribute is still -1, so moving the cursor silently snaps it back to line 0. Deferring to the next refresh tick means layout has computed line numbers and the move actually lands on the right row. If the URL no longer resolves (tab closed, saved tab removed, filter excluded it), the cursor stays at 0 as a fallback.

**Startup cursor parked.** On first paint, `on_mount` flips `cursor_active = False` so the hover dim doesn't land on the Workspace row before the user has navigated. Any motion (internal j/k or external cycle) reactivates via `_activate_cursor` and the dim resumes.

All programmatic cursor motion uses `move_cursor` rather than `select_node` because `select_node` posts a `Tree.NodeSelected` message — see "Enter routing" below.

**Enter routing — why `move_cursor` over `select_node`.** Textual's `Tree` widget owns the `enter` key via its own built-in `Binding("enter", "select_cursor")`; because the tree is the focused widget, that binding wins and an App-level `Binding("enter", ...)` would never fire. `BmApp` therefore listens for `Tree.NodeSelected` at the App level (`on_tree_node_selected`) and translates it into `action_activate` for leaves whose `.data` is a `Row`. Group-header branches have `data=None` and fall through silently — Tree's own auto-expand hook handles their expand/collapse. The knock-on consequence: `Tree.select_node(leaf)` *also* posts `NodeSelected`, which our handler would now spuriously interpret as an Enter press. Every programmatic cursor move — `_restore_cursor` and `action_collapse`'s "move to parent" fallback — therefore uses `move_cursor` (motion only, no message) instead. Helps behavior stay correct across the 300 ms live-refresh rebuild (would re-activate the cursor tab on every tick that rebuilds) and pressing `h` on a leaf (would collapse/expand its parent group as a side effect).

**Windowrule** (`~/.config/hypr/looknfeel.conf`, same marker-comment pattern):

```
windowrule = no_shadow on, match:class com.ko.bm
```

bm runs with ghostty `background-opacity = 0.75` so the desktop shows through around the text. Hyprland's default drop-shadow renders a dark rim around that transparent window which reads as an "ugly frame"; `no_shadow` drops it. The omarchy border stays on so bm still matches the visual language of other ghostty windows.

**`bm focus` behavior.** First tries to locate a running bm by **process ancestry**: find the `bm-py` process, walk up its parent chain until a `ghostty` ancestor is found, then ask hyprctl for the window with that pid and focus it. This is robust against terminal-title quirks (ghostty shows the `-e` command as its default title; Textual's OSC 2 update may not land; tmux hijacks titles). The launcher *also* emits `OSC 2 ; bm BEL` before the TUI runs so the title is populated as a nice-to-have — but it isn't relied on for focus.

If no bm is running, `bm focus` spawns a new ghostty (using `bm.conf`) and runs `bm` inside it, then `place_bm_as_sidebar` polls hyprctl for the `com.ko.bm` window, runs `dispatch movewindow l` (nudges it to the left edge under dwindle) and `dispatch resizeactive exact $BM_SIDEBAR_WIDTH 100%` — so the sidebar lands in the same place every time rather than wherever focus happened to be.

Flow: `Super+Alt+H` → focus jumps to `bm` (or launches it as a left-edge sidebar) → vim-navigate → Enter or Esc → focus returns to chromium. `Super+Alt+L` sends you back to chromium any time. `Super+Alt+J/K` flip through chromium tabs from anywhere — terminal, editor, anything — without leaving your current app. Super+1-9, Super+H/J/K/L (single-Super, no Alt), and all other omarchy prefixes stay free for the rest of your workflow.

## Styling

`bm` inherits the user's main ghostty config (font, base theme, colors) and layers the following overrides via `files/config/ghostty/bm.conf`:

```
# GTK app-id — must be reverse-DNS. Hyprland windowrules match on this.
class = com.ko.bm

# Force a dedicated ghostty process so Super+Alt+H's spawn path gets a real
# window (not a D-Bus delegation that exits immediately).
gtk-single-instance = false

# Partially transparent — the desktop/wallpaper shows through around the
# text. The TUI's CSS marks every widget background transparent, so the
# cells ghostty actually punches through are the tree/search rows.
background-opacity = 0.75
background-blur = false

# Horizontal padding gives titles breathing room from the right edge. At
# opacity 0.75 the padding area blends with the cells (both at 75%), so it
# reads as margin, not an opaque frame. Vertical stays 0 so the bottom row
# hugs the window edge (sidebar feel).
window-padding-x = 10
window-padding-y = 0

# Drop the GTK titlebar — the black "bm" strip at the top breaks the
# edge-to-edge transparent look. Hyprland already manages the window.
window-decoration = false

# Extra per-row vertical breathing room (≈6px on a typical cell).
# Trade-off: airier rows at the cost of a few fewer visible at once.
adjust-cell-height = 30%
```

**Colors follow the active omarchy theme.** `bm/theme.py` reads `~/.config/omarchy/current/theme/colors.toml` at startup and registers a Textual theme mapping `accent`, `foreground`, `background`, `surface`, `panel`, plus the standard ANSI palette into Textual's color system. The `dark=` flag on the registered Theme is computed from the background's Rec. 709 luminance (`_is_dark`), so light omarchy themes (catppuccin-latte, flexoki-light, rose-pine, white) get the correct Textual auto-shades instead of a hardcoded `dark=True`. Switch omarchy themes → restart `bm` → the TUI picks up the new palette.

For paths that need exact hex values (the help-screen key column, Workspace/group headers, essentials row, active-tab highlight, and hover dim), the TUI bypasses `self.current_theme` and reads the raw TOML dict via `bm_theme.load_colors()`. Rationale: Textual 8.x's new Content/markup system parses `[#RRGGBB]` as a variable reference rather than a raw color, and the Theme object can also normalize values passed to fields like `secondary`. Reading the dict and passing a `rich.style.Style(color=hex)` to `Text.append` (or `Text.stylize`) is the one approach that reliably renders the literal per-theme hex.

**Transparency approach.** `tui.tcss` sets `background: transparent` on a universal `*` rule plus an explicit `App, Screen, Vertical, Container, Tree, Input` rule (Textual's built-in per-widget defaults beat a single `*` on specificity). Transparent widget backgrounds cause Textual to emit cells with the terminal's default background — which is exactly what ghostty's `background-opacity` applies to. The cursor row (`.tree--cursor`) and its secondary `.tree--highlight` also stay transparent — selection is signalled by `FolderTree.render_label` blending each row's own color toward the theme background (see "Hover dim" in the TUI Layout section), so differently-hued rows stay in their own palette on hover instead of all repainting to `$accent`. CSS keeps `text-style: not bold` on the cursor deliberately (not just omitted): Textual's built-in `.tree--cursor` component class sets `text-style: bold` and CSS cascades per-property, so dropping the declaration leaves the default in place. Explicit `not bold` is required to stop the cursor from bolding, which otherwise shifts glyph widths and makes the list jitter as the cursor moves. Bold-by-design rows (Workspace and the group headers) re-assert `bold=True` inside `render_label` so they stay bold under the cursor without re-enabling bold universally. Blur is deliberately **off** — we want to see the desktop, not a frosted pane.

**Trade-off accepted:** text inside the TUI stays fully opaque (it's terminal text, not an image), so on busy wallpapers the text may feel slightly thin at `0.75`. Adjust `background-opacity` up or down in `bm.conf` if the default isn't to taste.

## Browser choice

Plain **chromium** — ships with omarchy by default, so no migration installs it. Reliable `--remote-debugging-port` support, lightweight, no vendor account needed.

Vivaldi is **not** used here — its `--remote-debugging-port` support has historically been unreliable, and Vivaldi Sync already covers that browser's own tab/workspace sync story. The two browsers coexist: Vivaldi for everyday browsing with workspaces, Chromium (via `bm`) as the git-synced saved-tabs workspace.

Chromium launches with `--user-data-dir=~/.config/bm/profile` so it keeps a dedicated profile, disjoint from any other Chromium install.

## Python / Textual install

Install via **uv tool install**, pointing at the bundled package under `files/local/share/bm/`. Self-contained venv, fast install, no pollution of system Python. Falls back to `pipx install` if uv is missing.

## Migration plan

Lands as **two migration groups**: `019` (name: `bm-tool`) holds the install scripts; `020` (also `bm-tool`) holds final-cleanup scripts that only need to run during a true clean-slate test. Splitting the cleanup into its own group lets the fast dev loop rollback/re-migrate group `019` alone (preserving user data), while a full rollback + `020` wipes everything.

**Register both groups** in `migrate.sh` and `scripts/rollback/rollback.sh`:

```bash
declare -A GROUP_NAMES=(
  ...
  [018]="updates" [019]="bm-tool"
  [020]="bm-tool"
)
GROUP_ORDER=(000 001 002 003 004 005 006 007 008 009 010 011 012 013 014 015 016 017 018 019 020)
```

**Scripts** (sequence numbers continue from the last one in 018; the rename runs first so the new `bm` binary isn't shadowed by the old bash function). Filenames follow the komarchy convention of uniform 17-character basenames (`NNN-NNNNN-CCC-AAA`, where `CCC` is a 3-char category and `AAA` a 3-char action). Category `bms` = **b**ookmark-**m**anager **s**idebar; `bmd` = **b**ookmark-**m**arkdown (the renamed predecessor).

| Script | Purpose |
|---|---|
| `019-00108-bmd-ren.sh` | Rename the existing `bm()` bash function in `~/.bashrc` to `bmd()`, freeing `bm` as a command name. Idempotent: no-op if already renamed. |
| `019-00109-bms-uvi.sh` | Install `uv` via pacman (if missing) |
| `019-00110-bms-app.sh` | `uv tool install` the Textual `bm` package |
| `019-00111-bms-bin.sh` | Copy the `bm` launcher to `~/.local/bin/bm`, the dedicated Ghostty config to `~/.config/ghostty/bm.conf`, and seed `~/.config/omarchy/bm/saved-tabs.json` (preserving any existing one) |
| `019-00112-bms-hyp.sh` | Append Super+Alt+hjkl leader block and marker-comment windowrules block to Hyprland config |
| `020-00113-bmc-stb.sh` | Final-cleanup arming script (no-op marker). Reports saved-tabs.json and `~/.config/bm/` (chromium profile) presence; the real work happens on rollback. |

**Rollback behavior** (important for the `rollback → migrate` test cycle):

- `019-00110` rollback runs `uv cache clean bm` after uninstalling so subsequent installs don't hit a stale wheel cache
- `019-00111` rollback removes the launcher, ghostty config, ephemeral bm UI state (`bm.pid`, `state.json`), and `~/.cache/bm/` (favicon cache), but **preserves** `~/.config/omarchy/bm/saved-tabs.json` **and `~/.config/bm/profile/`** — the chromium profile holds auth cookies, saved passwords, and site permissions (e.g. notification blocks), so treating it as disposable forced re-login and re-blocking every dev cycle. Kept alongside saved-tabs.json on the fast-loop side
- `020-00113` rollback removes `~/.config/omarchy/bm/saved-tabs.json` (and `rmdir`s the parent dir if empty) **plus `~/.config/bm/` in full** (chromium profile + any remaining UI state) — use this when you actually want a fresh-user clean slate (rollback both groups via `[Rollback All]`, then re-migrate)

**Interaction with `018-00073-bkm-als.sh`**: the existing migration that installs `bm()` is not edited. Fresh installs run it, get `bm()` in `.bashrc`, then `019-00108-bmd-ren.sh` immediately converts it to `bmd()`. Already-migrated users just run the 019 rename. The rollback of `019-00108-bmd-ren.sh` restores `bm()` → consistent with the original 018 migration.

Chromium is not installed by a migration — omarchy ships with it, so `bm` relies on that. If you wipe omarchy's defaults, reinstall `chromium` manually before running these.

## Phased rollout

- **Phase 1** (shipped) — Textual TUI with open-or-switch, saved tabs with groups, loose-leaf rendering for open-but-unsaved tabs (with URL-based pairing that deduplicates saved↔live on a first-match basis), Nerd-Font glyphs on each row, Workspace/Essentials header rows, theme-aware per-row color tiers + hover dim + tab_id-based active-tab highlight that follows manual chromium tab switches within 300 ms, Hyprland tiling, `bm` CLI subcommands (`open`, `save`, `list`, `rm`, `next`, `prev`) for scripted use, signal-based Super+Alt+J/K cycle that walks every tree row (Essentials + Saved + loose live) from any app, diff-guarded 300 ms refresh tick, **inline rename** with terminal-style inverted cursor, arrow-key motion through the buffer, viewport scroll for overflow, `[rename]` status-bar marker, and Tree binding-leak gates that keep stray keystrokes from scrolling the tree or double-activating the renamed tab on commit.
- **Phase 2** — polish: Kitty-graphics favicons (background fetch + cache already wired in `bm.favicon`; render path and multi-cell Tree variant still to build), compact-mode toggle layered on top of the graphics path (see "Compact mode" under Favicons), drag-to-reorder saved tabs, bulk import/export, search-across-tab-content via CDP `Runtime.evaluate`, per-group colors.
- **Phase 3** *(optional)* — Neovim plugin that reads the same `saved-tabs.json` and hits the same CDP endpoints for in-editor tab jumps (via Telescope / fzf-lua picker). Supplementary to `bm`, not a replacement.

## Resolved decisions

All four originally-open decisions landed as follows:

- **Sidebar width** — 300 px (tunable via `BM_SIDEBAR_WIDTH` env var)
- **Group model** — flat `group` string per tab
- **Enter behavior** — activates the tab and raises chromium (focus shifts to the browser); bm stays running in the background. Explicit exit is `q` / `Esc`, which also closes chromium (they're paired).
- **Auto-launch chromium** — yes. If CDP isn't reachable on `:9222`, `bm` spawns a dedicated chromium profile (`~/.config/bm/profile`) before running the TUI

## Trade-offs vs. Zen / Vivaldi Sync

| What this wins | What this loses |
|---|---|
| Saved tabs are plain JSON in git — diffable, scriptable, reviewable | No live tab sync across machines — only saved tabs travel |
| No vendor account, no cloud dependency | No mobile companion |
| Fully keyboard-driven, vim-native | You maintain the code |
| Reuses your existing terminal, font, theme, Hyprland setup | Less polished than Arc/Zen out of the box |
| One codebase drives CLI, TUI, and optional nvim plugin | |
