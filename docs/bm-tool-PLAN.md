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
| `bm browser` | Focus the bm-launched chromium window. Reads `~/.config/bm/chromium.pid` (written by `launcher._spawn`) and runs `hyprctl dispatch focuswindow pid:NNN`. Bound to Super+Alt+L. Silent no-op when bm chromium isn't running. PID-based because chromium ignores `--class=` on Wayland. |
| `bm open <url>` | Open-or-switch: if URL is already an open tab, activate it; otherwise open it in a new tab. Used by Hyprland keybinds and scripts. |
| `bm save [--group <name>] [--workspace <name>]` | Save the tab currently focused in chromium to `saved-tabs.json` (default group: `Unsorted`; default workspace: current). Distinct from the TUI's `s`, which saves the *highlighted* row — the CLI has no cursor, so it follows chromium's active tab. |
| `bm list [--workspace <name>]` | Print saved tabs as JSON (scripting hook). Default = current workspace; `--workspace <name>` filters to a specific one. |
| `bm rm <url>` | Remove every saved tab matching URL across all groups and workspaces (no id arg, so all matches go) |
| `bm workspace list` | Print workspaces (id, name, current marker) as JSON. |
| `bm workspace create <name>` | Append a new workspace to `workspaces[]` (empty groups, empty open-tab list). |
| `bm workspace rm <name>` | Destroy workspace + its saved tabs + its open-tab state. Refuses on the only remaining workspace. Non-interactive — no y/N. |
| `bm workspace switch <name>` | If a bm TUI is running, signal it to run the switch flow; else just update `state.currentWorkspace` so the next bm launch boots into it. |
| `bm workspace next` | Signal the running bm TUI to cycle to the next workspace in `workspaces[]` (wraps). Mirrors the in-bm `;` keybind. Bound to Hyprland's Super+Alt+;. Silent no-op when the TUI isn't running. |
| `bm next` | Signal the running bm TUI to step its cursor down one row and activate. Mirrors internal `j`+Enter so the external cycle walks the same tree the user sees — Essentials, Saved rows, then loose live leaves, skipping Workspace and group headers. Bound to Hyprland's Super+Alt+J. Silent no-op when the TUI isn't running. |
| `bm prev` | Same as `bm next` but `k`+Enter (cursor up). Bound to Super+Alt+K. |

The Textual TUI and the subcommands both drive the same Python module internally — no duplicated logic. Most CLI subcommands go through `launcher.ensure_up()`, so if chromium was closed between invocations they transparently respawn it (with the session-restore flow above) before running. The exception is `bm next` / `bm prev` / `bm workspace next`: those don't talk to chromium at all — they `os.kill(pid, SIGUSR1/SIGUSR2/SIGRTMIN)` the running bm TUI (PID read from `~/.config/bm/bm.pid`) and let the TUI handle motion / activation / workspace cycling in-process. Silent no-op when the TUI isn't running (PID file missing or points to a dead process). Since bm+chromium are paired via the launcher, "TUI gone" also means chromium is gone, so there's nothing meaningful to cycle.

**Bash wrapper allowlist.** The `bm` entry point is a bash wrapper at `files/local/bin/bm` that handles `bm` / `bm focus` directly (terminal management, ghostty spawn) and forwards everything else to the Python `bm-py` via a case-statement allowlist. The allowlist explicitly enumerates which subcommands are valid — anything else is rejected with `unknown subcommand` rather than being silently passed through. New subcommands must be added to both the click registration in `cli.py` *and* the bash wrapper's case allowlist, otherwise the Python side is registered but the keybind invocation falls into the unknown branch.

## Components

| Path | Role |
|---|---|
| `files/local/bin/bm` | Entry point — runs TUI inline (no args) or handles subcommands (`focus`, `open`, `save`, `list`, `rm`, `next`, `prev`) |
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

The Python TUI uses `httpx` to call these same endpoints. Raising the Chromium window when activating from `bm` uses `hyprctl dispatch focuswindow pid:NNN`, where NNN is the chromium PID captured at spawn time and persisted to `~/.config/bm/chromium.pid`. Class-based matching (`class:chromium`) was abandoned because chromium on Wayland ignores `--class=` and hardcodes its app_id, so any class match would non-deterministically focus *any* chromium window the user has running. PID is exact — `launcher._spawn` writes `Popen().pid` after spawn, `close_chromium` unlinks the file on shutdown, `actions.raise_chromium` reads the PID and validates the process is still alive (`os.kill(pid, 0)`) before dispatching, silently no-oping and dropping a stale file otherwise.

## Textual TUI Layout

Two stacked Textual `Tree` widgets inside a single `Vertical`:

- **`#tree`** — main list (`height: 1fr`). A custom `FolderTree(Tree)` subclass replaces Textual's default `▶`/`▼` chevrons with Nerd-Font folder glyphs (closed `` / open ``) and renders those glyphs *inline in `render_label`* (ICON_NODE is set empty) so the glyph and label share a single style and can be recolored together. Top-level rows, in render order:
  - **Workspace** — title row (accent + bold, same style as the help screen's "Keybindings" title) that anchors the current saved-tab workspace. Placeholder for workspace-level actions; today it has no children. `_rebuild_tree` appends an unconditional `_SpacerMarker` braille-blank leaf directly below the Workspace row so the sidebar layout stays stable across states (clean slate, groups only, essentials + groups) — without it, a clean-slate or group-only tree would paint the Workspace row butting directly against the next row.
  - **Essentials** — top-level cyan leaves (no folder header), data-driven from `self._saved` filtered by `group == "Essentials"`. Saving via `e` adds to this section; renaming/deleting work the same as any saved row. Renders only when the section has rows; when present it contributes a trailing spacer separating it from the groups below. Cyan styling is applied in `render_label`, keyed on `row.group == ESSENTIALS_GROUP`.
  - **`<group>`** — one branch per saved-tab group (accent + bold header, folder glyph + name only — no `Saved:` prefix and no member count). Saved rows render *before* loose live tabs so bookmarked content reads first and open-but-unsaved tabs collect below. The Essentials group is excluded from this section (it renders above).
  - **Divider** — a single dim horizontal rule (U+2500 at ~0.1 foreground opacity) painted across the tree width, separating saved folders from loose live leaves. Only rendered when there are loose live leaves to show. Styled as a ghost rule because the other section breaks use braille-blank spacers — this boundary benefits from a visible cue since it separates two different *kinds* of rows (folders above, loose leaves below).
  - **Loose live leaves** — every live chromium tab whose URL isn't already represented by a saved row, rendered as top-level leaves (same shape as Essentials: no group header, each tab on its own row at the root). See "Saved↔live pairing" below for how duplicates are handled.

  This is the only focusable widget. Tree `guide_depth` is `1` (minimum viable indent) and the `├─ └─ │` guide lines are hidden via CSS (`.tree--guides` color set transparent) so the tree reads as a clean column.
- **`#search-tree`** — single-row leaf at the bottom (`height: 1`). Multiplexed across three primary uses with priority: **active search > ephemeral status > committed filter > empty**, plus a **mode-marker suffix** (`[rename]` or `[preview]`) that rides alongside whichever primary is showing, **except** during active search (would fight the blinking prompt) and during an ephemeral status message (the tag would push the message around; `_blink_cursor` re-renders when the status times out and the suffix comes back).
  - Active search: `/foo█` (blinking cursor while typing)
  - Ephemeral status: transient notification like `Saved Tab`, `Moved to <group>` / `Already in <group>`, `Closed Tab`, `Removed Tab`, `Updated URL`, `Renamed Tab` / `Renamed Group`, or `Failed to activate (…)` / `Failed to close (…)`, rendered at **0.65 foreground opacity** (readable but clearly non-focal, via `_faded_fg(0.65)`) and auto-cleared after `STATUS_DURATION` (3s). Kept deliberately short — no title embedded in the message, since the cursor already shows which row was acted on.
  - Committed filter: `/foo` (no cursor) once the user hits enter on a search
  - Mode-marker suffix: `[rename]`, `[edit url]`, `[new group]`, or `[preview]` rendered at **0.35 foreground opacity** via `_faded_fg(0.35)` — noticeably dimmer than the 0.65 status tier, because it's a persistent mode marker that should sit quietly at the edge rather than compete with transient messages on the left. Exactly one marker shows at a time. Priority: `[rename]` (covers tab rename and group rename) > `[edit url]` > `[new group]` > `[preview]` — rename / edit-url / new-group are modal edits; preview is passive. The save-to-existing picker (`s`) **owns the entire bar** while open and goes two rows tall: header `Save to:    (↑/↓)` (label + arrow hint both at `_faded_fg(0.35)`, hint right-aligned via braille-blank padding) and a status row showing the current group name on its own line (special bucket rendered as `[Essentials]`). The widget bumps to `height: 2` for the picker and reverts to `height: 1` for every other mode. The picker suppresses every primary and suffix while open; closing it restores whatever marker would otherwise be active. **Right-aligned** suffix at the opposite end of the row; primary content stays left-aligned with the one-cell braille-blank inset, and braille-blank padding between them is computed from `search_tree.size.width` to push the suffix to the edge. `on_resize` re-renders so the alignment tracks terminal-width changes. On the one call that flips `display:False→True` the widget hasn't been laid out yet (`size.width == 0`); that case falls back to a minimum gap and schedules `call_after_refresh(self._update_search_tree)` so the suffix snaps to the right edge on the next paint instead of visibly sliding over from the left. Exiting an edit mode restores `[preview]` automatically — `_in_preview_mode` is independent state, so once the edit clears, the next `_update_search_tree` call naturally falls through to the preview branch.
  - Hidden entirely when none of the above applies — the main tree fills the viewport

```
╭─ bm ──────────────────────────────────────────╮
│ Workspace                                     │  ← accent + bold (title tier)
│                                               │
│  ChatGPT                                      │  ← color6 cyan (essentials)
│  Claude AI                                    │
│  Google                                       │
│                                               │
│  Work                                         │  ← accent + bold (group header, name only)
│   [] Azure Portal                             │
│   [] Jira – TEAM board                        │  ← color11 yellow = active tab
│   ...                                         │
│  Personal                                     │
│  Reading                                      │
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
| Title | `accent` | bold | Workspace, `<group>` headers |
| Essentials | `color6` (secondary / cyan) | regular | any saved row with `group == "Essentials"` |
| Active tab | `color11` (bright yellow) | regular | the row whose chromium `tab_id` matches the currently-active browser tab (updated by Enter/o/p/P, the external Super+Alt+J/K cycle, *and* manual tab switches inside chromium — see "Active-tab highlight" below) |
| Default | `foreground` | regular | all other tab rows |

**Sentinel markers** on `TreeNode.data` let `FolderTree.render_label` distinguish row types without string-matching labels: `_WorkspaceMarker`, `_GroupMarker`, `_SpacerMarker` (braille-blank separator rows), plus `_SearchMarker` and the `Row` dataclass for tab leaves. Essentials rows are plain `Row` data with `group == ESSENTIALS_GROUP`; the cyan styling and parent-level placement fall out of `row.group` matching in `render_label` and `_rebuild_tree` — no dedicated marker class.

**Per-row colors always re-applied in `render_label`.** Textual's `Tree.render_label` computes a `style` for each line that includes the widget's default color (typically `$text`) and stylizes the label copy with it via `super().render_label`. That overrides per-label color spans baked at `Text()` creation time — so labels like `Text("Workspace", style=Style(color=accent, bold=True))` would wash out to `$text`. `FolderTree.render_label` therefore resolves the intended color + bold per marker type and re-stylizes on every call, regardless of cursor state. Hover dim is a blended variant of the same per-row color (see below), so a parked cursor shows the full, non-dimmed color; a cursor-visible row shows the dim blend. Non-selected tab leaves (unstyled plain-string labels) get `foreground` explicitly for the same reason — Textual's base-style `$text` can differ from the omarchy theme's `foreground` (e.g. a "cream" omarchy foreground becoming pure white).

**Hover dim.** On the cursor row, `render_label` blends the row's own color toward the theme background via `FolderTree.HOVER_DIM_FACTOR` (`0.5` — halfway to bg). This preserves each row's hue (Workspace accent, Essentials cyan, etc.) instead of repainting to `$accent` which clashed with rows that intentionally use a different palette. ANSI `dim` is avoided because ghostty renders it as grayscale rather than a per-hue fade. Help-screen rows (`data=None`, multi-span labels with colored key + plain description) get a special cursor-only fallback: when parked they keep their per-span colors, but on the cursor row the whole label flattens to the dim foreground so it reads as "selected" without needing per-row colors.

**Esc-to-park cursor.** Esc has a five-tier hierarchy, in order: (1) cancel any active modal state — inline rename (tab or group), the new-group preview, or the save-to-existing picker — via `_cancel_edit`; (2) exit `/search` if active; (3) close the help screen if visible; (4) *park the cursor* (hide the hover dim while preserving `cursor_line`); (5) close bm + chromium. Park state rides on a `FolderTree.cursor_active: reactive[bool]` attribute — `render_label`'s `is_cursor` check gates on it, and the watcher calls `Tree._invalidate()` to clear the per-line render cache (a plain app-level flag wouldn't invalidate, so stale dim would linger up to 3s until `_refresh_live`'s rebuild cleared the cache as a side effect). Motion actions (`j/k/↑/↓/g/G/Ctrl+D/U/h/l`) call `_activate_cursor()` to flip it back on; action keys (`Enter`/`o`/`s`/`S`/`e`/`d`/`r`/`p`/`P`) deliberately do not — acting on a parked cursor still works against the last `cursor_line`, with no purposeless flash before the action lands.

**Inline edit modes.** Five edit flows share one buffer (`_rename_buffer`, `_rename_cursor`) and one render path (`FolderTree._render_edit_label`). At most one is active at a time, dispatched by which state field is set:

- **Saved-tab rename** (`_rename_kind = "saved"` + `_rename_saved_id`) — `r` on a saved leaf; commits via `store.rename_saved(saved_id, ...)` (persisted to `saved-tabs.json`). Matched on `SavedTab.id` so duplicate URLs (across groups or within one) each have their own rename target.
- **Live-tab session rename** (`_rename_kind = "live"` + `_rename_tab_id`) — `r` on a loose live leaf; commits to `BmApp._live_titles[tab_id]`, not persisted. See "Live-tab session rename" below. Matched on chromium tab_id so multiple tabs sharing a URL each get their own override. Two ambiguities are disambiguated by different keys: saved-vs-live with the same URL → `_rename_kind`; multiple same-URL rows of the same kind → `id` (saved) or `tab_id` (live). `render_label`, `_commit_rename_url`, and `_restore_edit_cursor` all consult `(_rename_kind, _rename_saved_id, _rename_tab_id)` together. `_rename_url` is still kept around as the "rename mode active" sentinel and seeds the buffer/display, but it's never used as a lookup key on its own anymore — URL alone is no longer unique in either kind.
- **Group rename** (`_rename_group`) — `r` on a group header; commits via `store.rename_group` (rewrites every member tab's `group` field). Blocked when `old == "Essentials"` — the section render path keys off that literal name.
- **URL edit** (`_url_edit_url` + `_url_edit_saved_id`) — `e` on a saved leaf; commits via `store.update_url(saved_id, new_url)`. Keyed on `SavedTab.id` so duplicate URLs each have their own URL-edit target, and so the commit doesn't need any session-pair migration — `_saved_session_tab_id` is also keyed on `id`, which is stable across URL changes. `_url_edit_url` is the "edit mode active" sentinel and seeds the buffer with the row's original URL; `_url_edit_saved_id` is the lookup key. `render_label`'s URL-edit branch matches on id (gated by `kind == "saved"` belt-and-suspenders — `e` already rejects live rows). `[edit url]` is the bottom-bar suffix marker.
- **New-group preview** (`_pending_new_group_row`) — `S` on a live row; a placeholder header and the tab leaf are inserted into the tree (nothing persisted) and the header is in edit mode prefilled with `"Group"`. Enter commits via `store.add_saved` with the typed name as the group; Esc rolls both the placeholder and the pending save back cleanly. The placeholder is keyed under the `""` key in `_saved_nodes` so cursor-restore helpers can find it.

`_render_edit_label` takes a `prefix` (glyph + spacing for tab rows, folder-glyph for group headers) and the shared buffer/cursor, and returns a custom multi-span Rich Text — accent-colored prefix + head, the char at the cursor position rendered with inverted colors (accent background, theme background as foreground) for the block-cursor look, then accent-colored tail — bypassing the rest of the styling flow (hover-dim, active-tab highlight) so edit mode owns the row's appearance. Inverting a char rather than inserting a separate block character is what makes the cursor read as a terminal-style cursor "on" a character. At end-of-buffer the inverted cell falls back to a phantom space so the cursor still has a 1-cell presence. The cursor block reuses `_cursor_on` and the existing 0.5s blink interval; during any edit mode the blink tick calls `tree._invalidate()` instead of `_update_search_tree` so the row repaints without touching the search-tree multiplexer.

`on_key` swallows every key except Esc while `_in_any_edit_mode()` is true: Enter commits via `_commit_edit` (dispatches to `_commit_rename_url` / `_commit_rename_group` / `_commit_edit_url` / `_commit_new_group`), Backspace / Delete remove the char before / at the cursor, Left / Right / Home / End (plus Ctrl+A / Ctrl+E) move the cursor by one, **Ctrl+Left / Ctrl+Right** jump by word boundaries (alphanumeric runs are "words"; everything else — `:/?&=.`-, spaces, etc. — is a separator, so on a long URL the cursor hops through `https | www | google | com | search | q | ibm | 5150`), **Ctrl+Backspace / Ctrl+Delete** delete the word to the left / right (same word-boundary walk, then splice out the run between the new cursor and the old position), **Ctrl+Shift+Backspace** clears the entire buffer (matches the muscle-memory chain `backspace` → 1 char, `ctrl+backspace` → word, `ctrl+shift+backspace` → all), printable chars (including space) insert at the cursor, and motion / other ctrl combos are consumed silently so stray presses can't scroll away or activate a different row mid-edit. Esc falls through to `action_quit_to_browser`, whose top tier calls `_cancel_edit` to clear every modal field at once. `_refresh_live` gates on `_in_modal_state()` alongside `_in_search_mode` / `_in_help_mode` — a 300ms tree rebuild during typing would wipe the edit state. Empty-buffer commits (`Enter` on a blank title / group name / URL) are a no-op cancel rather than persisting an empty string.

**Modal-state gates (App-level bindings).** In this Textual version, `event.stop()` in `on_key` does not reliably prevent App-level `Binding` dispatch from firing in parallel — observed first with arrow keys (Left collapsing the parent group under the rename row), then again when the user typed `r` / `s` / `e` / `S` mid-edit and the matching `Binding(...)` re-entered the action, resetting the buffer or saving to the wrong destination on top of the user's keystroke. Mitigation: two helpers, `_in_any_edit_mode()` (any of the five edit modes active — saved/live rename, group rename, URL edit, new-group preview) and `_in_modal_state()` (edit mode **or** save-to-existing picker active), and every motion action *and* every action bound to a printable key (`action_rename_saved`, `action_save_selected`, `action_save_new_group`, `action_edit_url`, `action_delete_saved`, `action_unload_tab`, `action_reload_saved`, `action_open_saved`, `action_focus_search`, `action_peek`, `action_toggle_preview`, `action_show_help`, `action_activate`, plus the collapse/expand/cursor/jump/half-page family) short-circuits with `if self._in_modal_state(): return` at the top. The printable-char insert in `on_key` still runs, so the keystroke lands in the buffer as intended.

**Widget-level binding gates (Tree space/enter).** App-level guards don't catch Tree's own widget bindings — `Binding("space", "toggle_node")` and `Binding("enter", "select_cursor")` fire from the focused Tree widget itself, bypassing App-level dispatch entirely. Two belts: (1) `on_key`'s edit-mode branch calls `event.prevent_default()` in addition to `event.stop()` — `stop()` only blocks bubbling, `prevent_default()` is what tells Textual to skip widget-level binding dispatch for this event. (2) `FolderTree` overrides `action_toggle_node` and `action_select_cursor` to noop during `_in_any_edit_mode()` / `_save_picker_row is not None`, *and* during the post-commit `_suppress_activate_until` window — that window is needed because our on_key commit clears the edit state *before* the Tree's parallel binding fires, so the plain edit-mode check alone would miss the toggle that happens one tick after Enter commits. Without these, a space in the middle of a group name would collapse the placeholder, and Enter-to-commit would also toggle the freshly-committed group closed.

**Commit-Enter suppression.** Pressing Enter to commit an edit hits two paths: (1) our `on_key` sees `enter`, calls `_commit_edit`, which dispatches to `_commit_rename_url` / `_commit_rename_group` / `_commit_new_group`, clears the matching edit field, and rebuilds the tree; (2) Textual's `Tree` posts a `NodeSelected` message from its own enter-binding, and its `action_select_cursor` *also* calls `node.toggle()` on branch nodes. The NodeSelected is processed *after* on_key returns, by which point the edit state is already cleared, so the existing mode gate in `on_tree_node_selected` misses and the tab activates right on top of the commit — user intent ("save") turns into "save AND open." Worse, on group-rename / new-group commits the `node.toggle()` collapses the freshly-committed group as a side effect. Fix: a **timestamp window** `_suppress_activate_until`. Every `_commit_*` handler sets it to `time.monotonic() + 0.5`. Three places honor the window: `on_tree_node_selected` skips `action_activate`; `FolderTree.action_select_cursor` noops (suppressing both the NodeSelected *and* the toggle); `FolderTree.action_toggle_node` noops (for the space case, which has the same race on non-Enter paths). An earlier attempt used a boolean flag cleared via `call_after_refresh` as a safety net; that clear fires *before* the queued NodeSelected is processed (refresh callbacks drain ahead of the message pump in this version), which cleared the flag too eagerly and let the activation leak through. The timestamp approach doesn't care about callback ordering — it auto-expires purely on wall-clock time, so the user's Enter-to-commit lands as "commit only" regardless of when NodeSelected happens to fire. 500ms is large enough to swallow the one bubbled NodeSelected and short enough that the user can't realistically click another row within the window.

**Edit-mode cursor lockdown.** Textual's `Tree` *also* has its own `up`/`down` key bindings that manipulate `cursor_line` *directly* — even the App-level action gates don't catch that path. Pressing up/down would drift the cursor to a neighboring row and take the inline edit UI with it (since `render_label` keys the edit field off the cursor row). `on_tree_node_highlighted` watches for this: while `_in_any_edit_mode()` is true, `_restore_edit_cursor` routes the cursor back to the right row — the matching URL leaf for tab rename, the matching group header for group rename, or the `""` placeholder header for new-group preview. Net effect: up/down arrows are a visible no-op during any edit; the edit field stays anchored.

**Rename viewport scroll.** The sidebar is narrow (~25 cells at the 300px default) and saved rows are nested one level under a group header, so typical titles overflow the visible row width. `render_label` computes `avail = size.width − 6` (overhead: indent + glyph + two spaces + safety) and, when `len(head) + 1 + len(tail)` exceeds `avail`, windows the buffer around `_rename_cursor`: if one side fits in its `half` budget the other side gets the leftover room; otherwise both sides clip to `half` cells each. The clipped boundary char on each truncated side is replaced with `…` so the truncation is visually obvious. Net effect: the cursor stays on-screen regardless of where the user moves it, and arrow-key navigation through a long title scrolls the visible window naturally rather than looking like "nothing happened." Tree CSS also sets `overflow-x: hidden` so a wide label can't push the whole ScrollView's virtual width and horizontally scroll the entire sidebar when the user presses arrows.

**Active-tab highlight.** `BmApp._active_tab_id` tracks the chromium tab id of the currently-active tab; `_active_url` mirrors it for non-render-path uses. Both update via a single `_mark_active(url, tab_id)` helper called from every activation path (`action_activate`, `_open_saved`, `_peek_row`). `render_label` paints any `Row` leaf whose `tab_id` equals `_active_tab_id` with `color11` — for live leaves that's their own chromium id, for saved rows it's the *paired* chromium id assigned in `_rebuild_tree` (see "Saved↔live pairing"). Matching on `tab_id` rather than `url` is deliberate: when the user has multiple chromium tabs on the same URL (three Yahoo tabs, say), URL matching would light up all three rows — `tab_id` isolates the one chromium is actually showing. The active row normally keeps its full `color11` under the cursor so the highlight reads as a constant beacon rather than a dim blend, but arriving on the active row gives no motion cue since the color doesn't change — so `render_label` applies a brief on-arrival flash: `FolderTree._reevaluate_active_dim` sets `_dim_active_row = True` the moment the cursor lands on the active row and schedules a `set_timer(ACTIVE_DIM_FLASH_S, _clear_active_dim)` (0.18s) that flips it back off. The dim gate becomes `is_cursor and (not is_selected or self._dim_active_row)` — a quick fade-in-fade-out that confirms the landing without washing out the highlight. The flash fires only on the *cursor-moved-onto-active* direction: `_reevaluate` diffs `(_active_tab_id, cursor_row.url, cursor_row.id, cursor_row.tab_id)` against a per-instance "last observed" tuple — id and tab_id ride alongside URL so duplicate URLs (allowed across and within groups) don't collapse to the same key — and gates on `cursor_moved and not active_changed`, so activation paths (Enter/o/peek/external cycle) — which set `_active_tab_id` → `_rebuild_tree` → `_restore_cursor` re-seats the cursor and trips the watcher with `active_changed=True` — produce no flash. The user just drove the activation, so they don't need a "you're here" cue for motion they didn't perform. Preview mode suppresses dim selectively: `render_label`'s dim expression is `is_cursor and (not is_selected or self._dim_active_row) and not suppress_dim`, where `suppress_dim = in_preview and isinstance(node.data, Row)` — i.e. only Row (tab-leaf) nodes skip the dim in preview. Rationale: every cursor landing on a tab drives a peek + `_mark_active` that repaints the row to `color11` within the ~100 ms debounce, so the color transition itself is the motion cue and a hover-dim blip on the row that's about to light up yellow just reads as visual noise. Workspace and group-header rows don't get peeked, so they keep the ordinary hover dim in preview mode — suppressing it there would hide the cursor entirely on those rows and motion through the tree would feel like it skipped them. The folder-glyph render at the bottom of `render_label` reuses the same `dim` boolean rather than keying on raw `is_cursor`, so the icon's dim state stays in lockstep with the text — earlier it half-dimmed (icon only) because its condition didn't account for the preview suppression. `_reevaluate_active_dim`'s arm gate also carries `not in_preview`, so the active-row flash is fully suppressed in preview regardless of node type. The key `(row.url, row.id, row.tab_id)` is compared across calls so a rebuild that re-seats the cursor on the same logical row short-circuits without re-triggering the flash. Invalidation is deferred via `call_after_refresh` rather than calling `_invalidate()` directly: Textual's `Tree._build` reassigns `cursor_line = cursor_node._line` at the tail of the build (with `always_update=True` firing the watcher even on same-value assignment), and a synchronous `_invalidate()` inside that watcher would clear `_tree_lines_cached` mid-build — tripping the `assert _tree_lines_cached is not None` right after `_build` returns in `_on_idle`.

**Saved↔live pairing — three passes, gated.** `_rebuild_tree` resolves which chromium tab (if any) backs each saved row in three priority-ordered passes. The first (session) is the only one that fires in steady state; the other two run *only on the very first rebuild* to seed pairings on startup.

1. **Session pairing pass (always runs, highest priority).** `BmApp._saved_session_tab_id: dict[str, str]` maps `SavedTab.id` → chromium tab id and is the source of truth for "this saved row owns this tab for the rest of the session." Populated by `_open_saved` / `_peek_row` whenever the user explicitly activates a saved row, and seeded on startup by the URL-based passes below. The pass walks the map: if the saved id is gone or the tab id is no longer in `self._live`, the entry is reaped; otherwise the row pairs with that tab id and the id goes into `consumed_tab_ids`. Crucially, this is the *only* pass that survives in-tab navigation — when the user clicks a link inside a paired tab and chromium reports a new URL, none of the URL-based passes match anymore, but the session pass keeps the pairing intact. Keying on `SavedTab.id` (not URL) is what lets duplicate URLs each have their own pair, and what makes URL edit / group move lossless without any migration code (the dict key is stable across both ops).
2. **Exact-URL pass (gated on `_initial_pair_done == False`).** Builds a FIFO queue per URL (`unpaired_by_url: dict[str, list[saved_id]]`, in saved-tabs.json order) of unpaired saved rows; walks `self._live` (first-seen stable order) and pairs each unconsumed live tab with the next saved row in the queue at that URL. On match, the tab id is consumed *and* written into `_saved_session_tab_id[saved_id]` — startup-time pairings are auto-claimed so the next URL drift doesn't unpair them. The FIFO queue is what handles **multiple saved rows at the same URL** (the duplicate-URLs feature): three saved `yahoo.com` rows with two open `yahoo.com` chromium tabs end up pairing the first two saved rows in json order, leaving the third unpaired.
3. **Loose-key fallback (gated on `_initial_pair_done == False`).** Some saved URLs carry volatile params that drift across reloads — Google's `?zx=<nonce>` cache-buster, redirect tracking like `gclid`/`fbclid`. Groups still-unconsumed live tabs by `_loose_url_key()` (scheme + host + path via `urlsplit`, raw URL on parse error) and pairs any unpaired saved row whose loose key has *exactly one* unconsumed candidate. Uniqueness gate is the safety net: three `google.com/` tabs → no fallback pair (would be a guess); saved row stays unpaired. Successful loose pairings also auto-claim the session under the saved row's id.

The gate on passes 2/3 (`_initial_pair_done`, flipped to `True` at the end of the first rebuild) is what stops surprising mid-session swallowing: a loose chromium tab the user navigates to a URL that happens to match a saved entry **stays loose** rather than getting silently absorbed into the saved row. After startup, only explicit activation (`Enter` / `o` / `p` / `P`) or a save commit (which calls `_claim_session_tab(saved_id, tab_id)` directly) can establish a new pairing. `_commit_edit_url` no longer needs to migrate the session entry — id-based pairing is stable across URL edit by definition.

`_claim_session_tab(saved_id, tab_id)` enforces one-to-one: it strips any prior saved-id claim on the same `tab_id` before recording the new one, so the session map can't end up pinning the same live tab to two different saved rows even if some other code path tries to.

**Session map persists across workspace switches.** Workspace switch / cycle / new-workspace commit do **not** clear `_saved_session_tab_id`. The map is keyed on `SavedTab.id` (uuid, unique across workspaces), chromium tabs persist across workspace switches (switching is a view filter, not a CDP op), and the rebuild's session reaper drops any entry whose saved_id was deleted with a removed workspace — so leftover entries can't go stale. Earlier the map was cleared on every switch; the result was that after cycling away and back, every saved row in the original workspace was unpaired, and the next click on one would `cdp.new_tab(...)` because `_activate_saved`'s unpaired branch always creates fresh. With the map preserved, a saved row the user has activated this session stays paired regardless of how many workspaces they cycle through. `_initial_pair_done` is still flipped to `False` on switch so the URL-pair seed runs for the incoming workspace's saved rows (which were filtered out at startup and never seeded).

**Per-workspace remembered active tab.** Each workspace remembers which row was last active (yellow highlight). `BmApp._workspace_active_tab: dict[workspace_id, tab_id]` is updated on every observation that lands a tab as active in the current workspace — chromium-driven (`_refresh_live`'s active_changed branch, after any cross-workspace flip so `current_workspace` already matches the tab's workspace) and bm-driven (`_mark_active`, called from Enter / peek / preview / open paths). `_remember_active_for_current_workspace()` gates the write on `_workspace_for_tab(active_tab_id) == current_workspace` so a ghost focus during the boot tick (when bm hasn't switched yet) can't pollute the slot. The render path keys on `BmApp._displayed_active_tab_id()`, which reads `_workspace_active_tab[current]` directly (rather than the global `_active_tab_id`); on a manual switch (`;`, `w`, `W`, workspace-delete recovery), the rebuild naturally picks up the incoming workspace's remembered tab and the highlight reappears on the right row. `_restore_workspace_active(target_id)` is a validator only — it drops the slot if the remembered tab has closed since last visit, but **doesn't touch `_active_tab_id` / `_active_url`** itself; the parallel `_activate_workspace_remembered_tab` (described next) is what proactively re-aligns those for manual switches. Splitting the validator from the activator was load-bearing in the earlier "view-filter only" design, where re-seating `_active_tab_id` on switch faked the highlight but tripped active_changed on the next refresh tick (chromium's focus didn't change, our `_active_tab_id` did) and the cross-workspace follow snapped right back — the "switches to the same workspace" bug. The user is in control — pressing Enter / `o` on a different row in the new workspace activates it in chromium and updates both the global `_active_tab_id` and the per-workspace slot. Stale entries (tab closed) are reaped on every refresh tick by `_sync_tab_workspace_tags`.

**Switch syncs chromium to the workspace's remembered tab.** Manual switches (`;`, `w`, Super+Alt+;, picker commit) call `_activate_workspace_remembered_tab` after `_restore_workspace_active`. It reads `_workspace_active_tab[current]`, confirms the tab is still in `_live`, calls `cdp.activate(remembered)`, then proactively sets `_active_tab_id` / `_active_url` to mirror so the next refresh tick observes no `active_changed` and skips a redundant rebuild. Same focus-restore dance as `_peek_row` (capture `_active_window_address` before the activate, reassert immediate + 80 ms-delayed via `_focus_window` after) so chromium's BringToFront doesn't strand keyboard focus on chromium when the user pressed `;` from bm — and conversely keeps focus on chromium when the user pressed Super+Alt+; from there. Without this, manual switches only flipped bm's view; chromium kept showing the *outgoing* workspace's tab until the user clicked something in the new tree (preview mode masked the gap because cursor-move peek activated rows for free). Early-returns on no remembered tab (fresh workspace, or `_restore_workspace_active` just dropped a stale slot) so the cycle proceeds without a chromium op — identical to the pre-feature behavior.

**`_pending_workspace_active_tab_id` — chromium MRU lag gate.** `cdp.activate` is synchronous, but chromium's `/json/list` MRU update can briefly trail the activate ack — a refresh tick caught in that window sees `chromium_focused.id == outgoing_tab` even though we just told chromium to focus the incoming workspace's tab. Without a gate, the resulting `active_changed=True` would run the cross-workspace follow on the lagging focused tab and flip `_current_workspace` *back* to the outgoing workspace; the next tick (chromium caught up) would flip forward again — visible as an intermittent flicker on the active-tab highlight, only when the lag straddled a tick. `_activate_workspace_remembered_tab` records the in-flight target on `_pending_workspace_active_tab_id`. `_refresh_live` checks this before processing `active_changed`: while the marker is set and `chromium_focused.id` doesn't match it, `active_changed` is forced to False for that tick. The marker clears the moment chromium agrees, or if the target tab has disappeared from `raw_tabs` entirely (closed externally) so the gate can't get stuck.

**`FolderTree._suspend_dim_eval` — flash suppression during rebuild.** Textual's base `Tree._build` reassigns `cursor_line = cursor_node._line` after populating `_tree_lines_cached` (see Textual's `_tree.py` around line 1294), which fires `watch_cursor_line` while the tree is mid-rebuild — `cursor_node` at that moment points at whatever transient row line N corresponds to in the half-built new tree. `_reevaluate_active_dim` running there updates `_last_active_tab_id` to the new workspace's active id while the cursor sits on the wrong row, so when `_restore_cursor`'s deferred callback finally placed the cursor on the real target, the eventual landing read as `active_changed=False` — exactly the user-driven "moved cursor onto already-active row" pattern that fires the dim-flash, except the user didn't drive it. Intermittent because whether `cursor_line` happened to land on a Row vs. a sentinel (Workspace title / group header / spacer) in the new tree depended on the outgoing workspace's cursor index. `_rebuild_tree` sets `tree._suspend_dim_eval = True` before any mutation, queues a final `_resume_dim_eval` callback (after the existing `_reset_cursor` / `_restore_cursor`) via `call_after_refresh` that clears the flag and runs `_reevaluate_active_dim` once with the cursor settled. All intermediate `_reevaluate` calls during the rebuild — Tree._build's transient ones, `_reset_cursor`'s, `_restore_cursor`'s — short-circuit; only the post-restore observation runs, diffing pre-rebuild anchors → final cursor + active state and correctly reading `active_changed=True` so the flash trigger skips.

**Per-workspace cursor memory.** Each workspace remembers where the cursor was when the user last left it. `BmApp._workspace_cursors: dict[str, dict]` maps workspace_id → row identity (`url` + `kind` + `saved_id` + `tab_id`); every workspace-switch path (`_cycle_workspace_step`, `_commit_workspace_picker`, `_commit_new_workspace`, and the workspace-delete `was_current` branch) calls `_save_workspace_cursor(outgoing_id)` to snapshot the live cursor before flipping `_current_workspace`, then sets `_pending_workspace_cursor = _workspace_cursors.get(incoming_id) or {}` so the rebuild's cursor-capture step uses the incoming workspace's saved snapshot instead of capturing from the live tree (which still shows the outgoing workspace at capture time). The empty-dict fallback (when there's no memory for the incoming workspace) is a deliberate signal: `_pending_workspace_cursor is not None` flips an `is_workspace_switch` flag inside `_rebuild_tree`, which then schedules an explicit `tree.cursor_line = 0` reset via `call_after_refresh` after the rebuild's add-leaf phase. Without this reset, Textual's `tree.clear()` retains the previous numeric `cursor_line`, so cycling from KO's row 14 to RPC would drop the cursor on whatever happens to render at row 14 in RPC (often a saved tab in the middle of the tree); the reset lands the cursor on the Workspace title row, same as a fresh boot. The deferred `_restore_cursor` call runs *after* the reset, so a workspace with saved cursor memory still moves the cursor to the right row — the reset is only visible when memory is missing or stale. Stale saved_id / tab_id entries (row deleted, tab closed) self-heal: `_restore_cursor` finds no match, doesn't move the cursor, and the prior reset leaves it at line 0. The deleted-workspace path explicitly pops the dead workspace's slot since it can never be re-entered. Slots are also dropped when the cursor is on a non-Row sentinel at switch time so re-entry defaults to line 0 cleanly.

**`_activate_saved` always creates a fresh tab when unpaired.** When `row.tab_id` is non-empty (session-paired), `_activate_saved` calls `cdp.activate(tab_id)` directly. When it's empty, it goes straight to `cdp.new_tab(row.url)` — deliberately *not* `actions.open_or_switch`, which would find-or-create by URL match and let a loose live tab whose URL happens to match the saved entry get adopted as the saved row's session. Mental model: saved tabs are their own sessions; a loose tab the user navigated to the same URL stays loose unless the user explicitly chose to claim it. (`actions.open_or_switch` is still used by the `bm open <url>` CLI subcommand, which legitimately wants find-or-create.)

**`_open_saved` / `_peek_row` ordering.** Both call `_refresh_live()` *before* `_mark_active()` so a tab that `_activate_saved` just *created* lands in `self._live` before the next `_rebuild_tree` runs. Without the reorder, `_mark_active`'s rebuild fires with stale `_live` — the session-pass reaper sees the just-claimed `tab_id` missing from `live_ids` and silently deletes the claim, leaving the saved row dim and the new tab as a loose leaf instead.

**`cdp._urls_match` — host + path + search-key agreement.** The CDP-side URL matcher used by `actions.open_or_switch` (and indirectly the `bm open <url>` CLI) was rewritten to balance Gmail-style loose match against search-engine collisions. Previously it stripped query and fragment entirely so `gmail.com` could match an open `gmail.com/?tab=rm&ogbl` — but that also collapsed `google.com/search?q=javascript` and `google.com/search?q=ibm+5150` onto the same tab. Now: hosts must match (case-insensitive), paths must match (trailing slash + fragment ignored, normalised via `urlsplit`), and **any search-query key in the target URL must agree with the live URL's value for that key**. `_SEARCH_QUERY_KEYS = {"q", "query", "search"}` — when the target URL specifies one of these, the live tab must carry the same value or the two are treated as different tabs; other params (`sca_esv`, `sourceid`, `ogbl`, tracking ids) are ignored, so chromium's response-side rewrites and SPA query drift don't force duplicate tabs. Gmail's bare-domain saved entry still matches an open `gmail.com/?tab=rm`; differing `q=` values stay distinct.

**Follow chromium's focused tab.** The user can switch tabs inside chromium (click a tab, Ctrl+Tab, close the active tab so chromium promotes the next one) without bm observing the event. `_refresh_live` closes that gap: chromium's `/json/list` returns pages in MRU order, so the first entry is whichever tab chromium is currently showing. Each refresh tick (every 300ms) compares `raw_tabs[0].id` to `self._active_tab_id`; on divergence, bm updates both `_active_url` and `_active_tab_id` to match, **and the bm cursor moves with the highlight** — `_restore_cursor` is scheduled (via `call_after_refresh`, after `_rebuild_tree`'s own prev-URL restore so the active-follow move wins) onto the new active row. Without the cursor follow, closing or switching tabs in chromium would leave the bm cursor stranded on the old (now-gone or no-longer-active) row. The active-follow path also parks the cursor (`tree.cursor_active = False`) for the duration of the rebuild and re-enables it inside the follow callback, so the brief line-0 stop after `tree.clear()` doesn't render the hover-dim on Workspace as a flash; the prior parked-state value is captured and restored, preserving an Esc-park the user had set. `active_changed` only fires for chromium-driven shifts (bm's own activations preset `_active_tab_id`), so normal j/k navigation in the sidebar isn't yanked.

**Cross-workspace follow.** If the now-focused chromium tab lives in a workspace other than the one bm is showing, `_refresh_live` auto-switches bm to that workspace before the rebuild fires. Decision is delegated to `_workspace_for_tab(tab_id)`: a tab paired with an Essentials saved row stays on the current workspace (Essentials render globally — no switch needed); a tab paired with a non-Essentials saved row maps to that saved row's workspace; a loose tab follows its `_tab_workspace` tag. When the target differs from current, the path saves the outgoing workspace's cursor (so a later switch back lands the user where they were), seeds `_pending_workspace_cursor` with a synthesized snapshot pointing at the chromium tab (kind="live" + tab_id; the saved-walk fallback in `_restore_cursor` keyed on `tab_id` finds it whether it ends up rendered as a loose leaf or a paired saved row in the new workspace), flips `_current_workspace` + persists, flips `_initial_pair_done = False` for the URL-pair seed, and posts the `Switched to <name>` status — same shape as a manual `;` cycle, just driven by chromium instead of the user. The session map is preserved (same rationale as the manual switch paths). User-flow consequence: clicking a Workday tab in chromium while bm shows the Personal workspace flips bm to Work, lands the cursor on the Workday row, and Personal's cursor is remembered for the next time you switch back. **Boot-tick guard:** the auto-switch is gated on `prior_active_tab_id` being non-empty — the very first observation of chromium focus (when `_active_tab_id` is still `""` from `__init__`) skips the workspace flip so bm respects the user's persisted `state.currentWorkspace` instead of being hijacked to whichever tab chromium happened to have focused at launch. After the first tick, every subsequent shift is followed normally.

**`_restore_cursor` matches paired saved rows by tab_id.** The follow path (and the cross-workspace switch above) calls `_restore_cursor` with `kind="live"` and the chromium `tab_id`. If the active tab is paired with a saved row, the loose-leaves walk misses (the tab isn't loose), and the saved walks now also accept a `tab_id` match — finding paired saved rows whose URL has drifted from the canonical saved URL (Workday OAuth redirect, SPA route changes, Google Sheets gid drift). Without this, follow only worked while saved↔live URLs still matched exactly, so the bm cursor would drift away from chromium's focus on every in-tab navigation that mutated the URL.

**Unpaired saved rows are dimmed.** Saved rows whose `tab_id` is empty (no live chromium tab is currently backing them) render with their source color blended toward the theme background by `FolderTree.UNPAIRED_DIM_FACTOR` (`0.4`, applied via `_unpaired_color`) *before* any cursor-hover blend. Slightly lighter than `HOVER_DIM_FACTOR` (`0.5`) so a cursor landing on an unpaired row still reads distinctly when the cursor's own blend stacks on top. Active rows can't reach this branch — `is_selected` requires `tab_id == _active_tab_id` which is non-empty. Net effect: at a glance the user can tell which saved entries are currently open in chromium and which are dormant, without any extra glyph or column.

## Keybinds (inside the TUI)

All tab-navigation logic lives inside `bm` — the global keybind just gets you there.

| Key | Action |
|---|---|
| `j` / `k` (or `↓` / `↑`, or `Shift+j` / `Shift+k` while searching) | Move down/up through tab list. `_skip_spacers(tree, direction)` runs after every motion action to step past `_SpacerMarker` leaves (the Workspace-below spacer plus the trailing spacer below Essentials), so the cursor never parks on a visually empty row. In help mode the helper short-circuits — the row at `_HELP_FIRST_ROW` is an intentional cursor-floor spacer owned by `_clamp_help_cursor`. In **preview mode** the cursor skips non-tab rows entirely and wraps at the tree edges — see "Cursor only rests on tab rows in preview" below. |
| `h` / `l` (or `←` / `→`, or `Shift+h` / `Shift+l` while searching) | Collapse/expand group, or switch section (Open ↔ Saved) |
| `g` / `G` (or `Home` / `End`) | Jump to top / bottom |
| `Ctrl+d` / `Ctrl+u` (or `PgDn` / `PgUp`) | Half page down / up |
| `⏎` | Activate selected tab (also raises chromium, returns focus to browser) |
| `o` | Open the selected row. Live rows → activate that chromium tab. Saved rows → activate the row's session tab if it has one, else create a fresh chromium tab at the saved URL via `cdp.new_tab` (no URL find-or-switch — see "`_activate_saved` always creates a fresh tab when unpaired"). |
| `t` | **New tab** — open a fresh chromium tab on `chrome://newtab/` and raise chromium so the user can start typing in the new-tab page's search box (or omnibox) immediately. Mirrors chromium's Ctrl+T from inside bm. Refresh ordering matches `_open_saved`: `_refresh_live()` runs before `_mark_active(tab.url, tab.id)` so the new tab id is in `self._live` before the rebuild and `_remember_active_for_current_workspace` records it as the workspace's active row. The tab gets workspace-tagged to the current workspace by the regular `_sync_tab_workspace_tags` pass. Status `New Tab`. No-op with `chromium not reachable` status if `launcher.ensure_up()` fails. |
| `s` | Save / move selected row via the bottom-bar picker. Two-line layout: header row `Save to:    (↑/↓)` (label and arrow hint both at `_faded_fg(0.35)`, hint right-aligned via braille-blank padding); status row shows the current group name on its own line, with the special bucket rendered as `[Essentials]`. The picker's group list is alphabetised user-created groups followed by `Essentials` pinned at the bottom — always non-empty. `↑/↓` cycle, `Enter` commits, `Esc` cancels. The picker always opens at index 0 (top of the list) regardless of prior history; predictable cursor over "remembered last group". On a **live** row → `store.add_saved` always appends a fresh row (uuid-based id, no URL dedup) so saving the same URL into a different group — or even into a group that already has it — creates a real second saved entry, status `Saved Tab`. On a **saved** row → `store.move_saved(row.id, group)` (status `Moved to <group>` or `Already in <group>`); the picker doubles as a relocate UI for saved entries, scoped to the specific row by id so duplicate-URL siblings stay put. |
| `S` | Save selected row to a **new** group. Inserts a placeholder group header (prefilled with `Group`, cursor at end) and the tab leaf into the tree in inline edit mode — true preview-before-commit, nothing persisted. `Enter` commits with the typed name (creates the group, saves the tab); `Esc` rolls everything back. `[new group]` rides in the status bar's right-aligned suffix slot. |
| `e` | **Edit URL** of a saved/essential row — inline edit (same buffer / cursor machinery as `r` rename) seeded with the row's current URL. Commits via `store.update_url(saved_id, new_url)` (keyed on `SavedTab.id` so duplicate URLs each have their own edit target); `[edit url]` rides in the status bar's right-aligned suffix slot. Live rows are rejected with status `Only saved tabs can have their URL edited` (chromium owns their URL). Earlier this key was a one-shot save-to-Essentials; that flow now lives at the bottom of the `s` picker, freeing `e` for editing. |
| `d` | **Delete** — every invocation routes through the shared **destructive-action confirm prompt** (`Delete <type>?    (y/N)`, see "Workspaces → Destructive-action confirm prompt"). On `y`/`Y` commits; anything else cancels with no status. Per row type: Workspace row → destroys workspace + its saved tabs + its open-tab state (blocked when only one workspace exists); Essentials leaf → `store.remove_saved(id)`; Group header → removes every saved tab in the group (header vanishes naturally on the next rebuild); Saved row (non-Essentials) → close paired chromium tab if any, then `store.remove_saved(id)`; Loose live row → `cdp.close_tab(tab_id)`. Status `Deleted <type>` after commit. Replaces the old layered "first close, then delete" semantic on saved rows — that path now lives entirely on `u` (unload). |
| `u` | **Unload tab** — closes the live tab on a loose live row, or the paired live tab on a saved row (saved entry stays); status `Closed Tab`. On an **unpaired saved** row, no-op — `u` never touches `saved-tabs.json`, so muscle memory of "u just closes" stays predictable across row kinds. Useful when you want to free chromium memory without risking a destructive press on an unpaired saved entry, and the only path to "close the tab without deleting the saved entry" now that `d` is single-step. |
| `w` | **Switch workspace** — bottom-bar two-line picker (same shape as `s`). Header `Switch to:    (↑/↓)`, status row shows current workspace name. Always opens at index 0. `↑/↓` cycle, `Enter` commits the switch (writes `state.currentWorkspace = new_id` and rebuilds — no CDP traffic), `Esc` cancels. Valid from any cursor location. |
| `W` | **New workspace** — preview-before-commit (same shape as `S`). Inserts a placeholder Workspace row in inline edit mode prefilled with `Workspace`. `Enter` creates the workspace (empty groups, empty open-tab list) and switches into it; `Esc` rolls back cleanly. `[new workspace]` rides in the bottom-bar suffix slot. |
| `;` | **Cycle to next workspace** — instant cycle, no picker UI. Advances `_current_workspace` by one in `workspaces[]`, wrapping at the end. Same recovery dance as the `w` picker commit (flip `_initial_pair_done = False` so URL-pair seeding can run for the incoming workspace's saved rows; the session map is preserved across the switch — see "Session map persists across workspace switches" below). Status `Switched to <name>`. No-op with `Only one workspace` status when `len(workspaces) < 2`. Mirrors the external Super+Alt+; binding via SIGRTMIN — both call the same `_cycle_workspace_step` helper, so internal and external cycles walk the same list in the same direction. |
| `r` | Rename — works on four cursor targets: a saved row (rewrites the title in `saved-tabs.json` via `store.rename_saved`), a live row (writes a session-only override into `_live_titles[tab_id]` — survives the rest of this bm session, not persisted), a `Saved: <group>` header (rewrites every member tab's `group` field via `store.rename_group`), or the **Workspace row** (rewrites the current workspace name via `store.rename_workspace(id, new_name)` — keyed on workspace `id` so the rename is lossless against tab `workspace` references). All four share one inline edit UI: glyph/header prefix + buffer with a terminal-style inverted block cursor in accent color. `[rename]` shows in the status bar at the same dim tier as `[preview]`, taking priority if preview mode was also on (restored automatically on exit). Enter commits (shows `Renamed Tab` / `Renamed Group` / `Renamed Workspace` status), Esc cancels. Inside the edit field: Left/Right move the cursor by one; Home/Ctrl+A and End/Ctrl+E jump to the ends; Backspace deletes the char before the cursor; Delete removes the char at the cursor; printable keys insert at the cursor. Other keys (motion bindings, ctrl combos, arrow keys that would otherwise scroll the tree) are consumed silently so stray presses can't scroll or activate mid-edit. An empty buffer on Enter is a no-op (cancel-equivalent). Group rename is blocked on `Essentials` (the section render path keys off this exact name). Long titles overflow the sidebar width; the visible window scrolls around the cursor with `…` on the clipped side(s). |
| `R` | **Reload saved tab** — close the paired live tab (if any), drop its session claim, then open a fresh chromium tab at `row.url` via `cdp.new_tab` and re-claim it via `_claim_session_tab`. Undoes any in-tab drift (link clicks, redirects, SPA navigation) by restoring the canonical URL stored in `saved-tabs.json`. Status `Reloaded Tab`. Live rows are rejected with status `Only saved tabs can be reloaded` — chromium owns their URL, there's no canonical to reload from. Refresh ordering matches `_open_saved`: `_refresh_live()` runs before `_mark_active()` so the freshly-created tab id is in `self._live` before the next rebuild, otherwise the session-pass reaper would silently drop the claim. |
| `/` | Filter search (narrows both sections; text appears in the bottom `#search-tree` leaf) |
| `n` / `N` | Next / previous search match |
| `p` | Peek — activate the selected tab in chromium without raising the chromium window (one-shot; keyboard focus stays in bm) |
| `P` | Toggle auto-preview mode — every cursor move auto-peeks. `[preview]` shows in the status line while on |
| `?` | Toggle help — renders a "Keybindings" reference inline in the main tree (see below) |
| `Esc` | Contextual dismiss, five tiers: (1) in any edit/picker mode, cancels via `_cancel_edit`; (2) in search, clears the filter; (3) in help, closes help; (4) with the cursor visible, parks the cursor (see "Esc-to-park cursor" above); (5) once parked, closes chromium and exits the TUI. |
| `q` | Immediate quit — bypasses the Esc tier ladder entirely and tears down chromium + the TUI in one step. Edit / search / save-picker modes already swallow `q` in `on_key` (printable in search, no-op in edit), so the binding only fires from idle navigation, where "quit now" is what the user wants. |

### Help screen (`?`)

Tap `?` to swap the tree contents for a keybind reference. Renders **inline in the same Tree** (not a separate widget) so the window's transparency is preserved — a prior Static-based layout painted the area opaque with `$background` regardless of CSS, which is why we stayed in the Tree.

Layout:

- **Title row** `Keybindings` in **bold accent** color.
- **Spacer row** — a single Braille-blank leaf.
- **Key column** right-aligned within a fixed width, padded with **Braille Pattern Blank (U+2800)**. Tree strips leading ASCII/Unicode whitespace from labels but U+2800 isn't classified as whitespace, so the padding survives and the column aligns cleanly.
- **Left margin** — one Braille-blank cell so the whole block has breathing room from the window edge (matches the status line's inset).
- **Key color** = the theme's `color6` (secondary, typically cyan), matching the Essentials row in the main tree for a consistent "command / action" visual. Falls back to `secondary` then `accent` if a theme doesn't expose `color6`. Earlier versions had a per-theme carve-out for osaka-jade; the universal `color6` mapping subsumes that cleanly.

Motion keys (`j/k`, arrows, `g/G`, `Ctrl+d/u`, `h/l`) keep working while help is visible so you can scroll the list. Modification actions (`Enter`, `o`, `t`, `s`, `S`, `e`, `d`, `u`, `r`, `R`, `w`, `W`, `;`) are short-circuited in help mode. `?` toggles out; `Esc` also walks the close tier ladder, and `q` quits immediately as anywhere else.

The `HELP_LINES` table that drives the rendered list mirrors the Keybindings section above. Workspace controls (`w` switch workspace, `W` new workspace, `;` next workspace) are listed alongside `r` rename and the rest of the saved-tab actions.

**Cursor floor in help mode.** Opening help parks the cursor on the blank spacer row (tree index 1), not the title. `action_cursor_up`, `action_half_page_up`, and `action_jump_top` clamp to that same floor so `k` / `Ctrl+U` / `g` can never land on row 0 (the `Keybindings` title). Row 1 is a braille-blank leaf — there's no visible text for the hover-dim to color — so help opens looking "unselected" and the title stays decorative.

## Peek (`p`) and auto-preview mode (`P`)

Two keys, one underlying primitive. `p` fires a **one-shot peek**: activate the selected tab in chromium while keeping keyboard focus on the bm terminal. `P` toggles **auto-preview mode**, where every cursor motion auto-peeks — you can scroll with `j/k` and watch chromium redraw beside you. A faded `[preview]` tag appears in the `#search-tree` status row while mode is on, and persists alongside a committed filter.

Both paths funnel through one helper — `_peek_row(row)` — so peek and auto-preview share the activate-and-restore-focus dance below.

**Two row kinds, two behaviors.**

- **Live tab** → `cdp.activate(tab_id)`. Flips chromium's active tab.
- **Saved tab** → `_activate_saved(row, raise_window=False)`. Activates the row's session tab if paired, otherwise creates a fresh chromium tab at the saved URL via `cdp.new_tab`. The `raise_window` kwarg skips `raise_chromium()` for this path. Peeking many different saved URLs accumulates tabs in chromium — that's the cost of the feature, not a bug; peeking the same saved row repeatedly re-activates its session tab.

**Focus-theft workaround.** CDP's `/json/activate` (and `Page.bringToFront`) internally call chromium's `BringToFront`, which raises the chromium window on hyprland — there is no CDP flag to suppress it, so skipping our own `raise_chromium()` isn't enough on its own. `_peek_row` therefore:

1. captures the currently-focused window via `hyprctl activewindow -j` (that's bm, since the user just pressed a key in it),
2. calls the CDP activate,
3. reasserts focus on the captured address via `hyprctl dispatch focuswindow address:<addr>` immediately,
4. schedules one delayed retry at 80 ms — chromium's window-activation event can arrive asynchronously, after our sync refocus lands, and without this retry focus occasionally flips back to chromium.

The `_active_window_address` / `_focus_window` helpers in `bm/tui.py` are tiny hyprctl wrappers; they no-op cleanly if `hyprctl` isn't on PATH (non-hyprland use).

**Debouncing (auto-preview only).** Cursor moves schedule `_do_preview` on a 100ms timer (`_preview_debounce`). Mashing `j` coalesces into a single CDP call per pause instead of flickering chromium through every intermediate tab. Each new motion cancels the pending timer and starts a fresh one, so the preview always reflects where the cursor actually stopped. One-shot `p` bypasses this — it peeks immediately.

**Motion hook.** Auto-preview is driven by Textual's `Tree.NodeHighlighted` event (via `on_tree_node_highlighted`), not by patching each motion action. One handler covers `j/k`, arrows, `g/G`, `Ctrl+d/u`, shift variants, and any future motion binding — whatever moves the cursor fires the event.

**Cursor only rests on tab rows in preview.** Preview is a tab cycler — Workspace / group-header / spacer rows are dead stops there (no peek fires, no `color11` transition), so motion keys skip them. Two helpers divide the work:

- **`_preview_cursor_step(tree, direction)`** — dedicated to single-step `j`/`k`/`J`/`K`. In preview, `action_cursor_down`/`action_cursor_up` short-circuit the normal `tree.action_cursor_*()` path and call this instead. It walks one action-step at a time, skipping non-Row nodes, and **wraps at the tree edges** — pressing `j` on the last tab jumps to the first, `k` on the first tab jumps to the last, matching the external Super+Alt+J/K cycle. Edge detection is `cursor_line` unchanged after a step → reseat to `0` or `last_line` and continue scanning. Bounded by `last_line + 2` so an empty-tabs tree can't spin forever.
- **`_skip_non_tabs_if_previewing(tree, direction)`** — used by jump (`g`/`G`) and half-page (`Ctrl+D`/`Ctrl+U`) actions after their own motion lands. It only skips in the given direction and **does not wrap**: these are "move a chunk" actions and teleporting to the other end mid-skip would be surprising. `g` in preview lands on the first tab (Essentials row if present, otherwise the first group's first tab); `G` lands on the last tab.

`h`/`l` (collapse/expand) stay unchanged — they don't move the cursor across row kinds. Leaving preview restores full motion across Workspace / group rows. The cursor *can* briefly sit on a non-Row in preview if `P` is toggled on while the cursor was already parked there — motion immediately corrects it, and `render_label` keeps the hover-dim on non-Row nodes so the cursor stays visible in that transient state.


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

Flat list, `group` as a string per tab, `id` as a uuid hex per tab, `workspace` as a uuid hex pointer into `workspaces[]`. Keeps the schema easy to hand-edit and trivial for any future tool (nvim plugin, scripts, other machines) to read:

```json
{
  "version": 2,
  "workspaces": [
    { "id": "5b7ac1e8d4a24f9e9c1a3c8b2f1e4d56", "name": "Workspace" }
  ],
  "tabs": [
    {
      "id": "a094c8b6c3ef41b59a2d52f7c1d4e9b3",
      "title": "ChatGPT",
      "url": "https://chatgpt.com",
      "group": "Essentials",
      "added": "2026-04-23"
    },
    {
      "id": "ac6dfe0ad2f046c7b3a18e4c9b0d2e1f",
      "title": "GitHub",
      "url": "https://github.com",
      "group": "Work",
      "workspace": "5b7ac1e8d4a24f9e9c1a3c8b2f1e4d56",
      "added": "2026-04-17"
    }
  ]
}
```

`group` is opaque to the store layer — any string the user types becomes a group. The TUI special-cases the literal string `Essentials` for rendering (top-level cyan leaves above the saved groups, no folder header) and blocks renaming *to* or *from* it via group rename. Empty groups are unrepresentable: removing the last tab in a group makes the header disappear naturally on the next rebuild.

`workspace` references `workspaces[].id` (uuid hex). Names are mutable, ids are stable, so workspace renames are lossless. Essentials tabs (`group == "Essentials"`) omit the `workspace` field; the loader treats them as global regardless of what's in the field, so a stray value can't take an Essential out of circulation. Group names are unique *within* a workspace — two different workspaces can both have a `Reading` group and they're independent. The render path filters non-Essentials saved tabs by `tab.workspace == current_workspace_id`. See "Workspaces" below for the full model and `version` migration story.

**Identity is `id`, not URL.** Each saved row has a stable uuid hex `id` minted at creation time. Every store mutation — `remove_saved`, `move_saved`, `update_url`, `rename_saved` — keys on `id`. The in-memory `Row` carries `id`; `BmApp._saved_session_tab_id` keys on `id` (not URL); render-path matching for inline rename / URL edit / `_restore_edit_cursor` keys on `id`. Net effect: **duplicate URLs are allowed anywhere** — same URL across groups, same URL within a single group, same URL as an already-saved entry — and each row has its own pairing slot, its own rename target, its own delete target. Pre-`id` `saved-tabs.json` files are backwards-compatible: `store.load_saved` backfills missing ids with fresh uuids and writes them back to disk on first read so the same row gets the same id across processes (`bm save` / `bm rm` / the running TUI). One side benefit of id-keyed pairing: URL edit and group move are lossless without any session-pair migration code — the dict key doesn't change under either op.

The CLI `bm rm <url>` keeps its URL-only signature and removes **every** matching entry across all groups — natural one-shot semantic when there's no id to disambiguate. `add_saved` (used by `bm save` and the TUI's save picker / new-group preview) always appends a fresh row; pressing `bm save` twice on the same chromium tab creates two saved entries (same as the TUI's `s` picker behavior on a live row).

## Workspaces

Multiple named saved-tab containers (e.g. `Workspace`, `Work`, `Coding`). Each workspace owns its own groups and its own view of which chromium tabs "belong" to it. Essentials are global — visible in every workspace's sidebar regardless. Switching workspaces is a **view filter, not a tab swap**: chromium tabs are never opened or closed by a switch; the loose-live-leaves section just filters down to the tabs tagged with the current workspace.

**Identity is workspace `id` (uuid hex), not name.** Tabs reference `workspace: <id>`, so renames are lossless. Group names are unique per-workspace (two workspaces can both have `Reading`), filtered at render time by `tab.workspace == current_workspace_id` (Essentials excluded — they render globally regardless of `workspace`).

### v1 → v2 auto-migration

`store.load_saved` detects `version` missing or `< 2` and:

1. Mints one workspace `{ id: <new uuid>, name: "Workspace" }` (matches the existing title-row label so users with no workspace expectations see the same UI).
2. Sets `tab.workspace = <new id>` for every saved tab whose `group != "Essentials"`. Essentials tabs get no `workspace` field.
3. Writes `version: 2`, `workspaces[]`, and the upgraded `tabs[]` back to disk. Same once-and-done shape as the existing `id` backfill in `from_json`.

On the first mount after migration, every currently-open chromium tab is tagged with the seed workspace's id (see "Per-tab workspace tag" below) so nothing visible disappears under the user.

### Per-tab workspace tag

Every chromium tab carries a workspace tag, stamped at creation time = the workspace that was current when the tab was opened. The tag follows the tab through URL navigation, save/unsave, pair/unpair — it never changes once set. This is what makes workspace switching cheap: no CDP traffic, just a view filter.

**In-memory truth** lives on `BmApp`:

```python
_tab_workspace: dict[str, str]  # chromium tab_id → workspace_id
```

The **loose live leaves** section is filtered by `_tab_workspace.get(tab.id) == current_workspace_id`. Loose tabs from other workspaces are simply not rendered. Saved-row pairing is unchanged — it's global by tab_id, so a paired Essentials row renders identically in every workspace, and a paired non-Essentials saved row renders in its own workspace's view (because the saved row is filtered, not the pairing).

**Persisted across bm/chromium restarts** in `~/.config/bm/state.json`:

```json
{
  "currentWorkspace": "<workspace_id>",
  "openTabUrlsByWorkspace": {
    "<workspace_id>": ["https://...", "https://..."]
  }
}
```

URLs, not tab_ids — chromium tab_ids reset across chromium restarts, and bm + chromium are paired processes (exiting bm closes chromium). On every detected tab change (300ms refresh tick spotting added/removed ids), bm rewrites the URL list for the affected workspace so the on-disk state is always close to current — cheap, no flush-on-exit-only data-loss risk.

### Lifecycle

**Startup** (after chromium session-restore reopens all previous tabs):

1. Load `state.json`. `cdp.list()` returns the session-restored tabs.
2. For each tab T: look up T.url in `openTabUrlsByWorkspace` (across all workspaces, first-match wins for duplicate URLs). If found, set `_tab_workspace[T.id] = workspace_id`. If not, default to `currentWorkspace`.
3. Render. Loose leaves filter by current workspace's tag.

**During session**:

- New tab detected (chromium tab_id appears in `/json/list` that wasn't there last tick) → `_tab_workspace[T.id] = current_workspace_id`. Append T.url to `openTabUrlsByWorkspace[current]`. Persist `state.json`.
- Closed tab detected (tab_id missing) → drop it from `_tab_workspace`. Drop the (first matching) URL from `openTabUrlsByWorkspace[its_workspace]`. Persist `state.json`.
- URL navigation within a tab → tag unchanged. The `openTabUrlsByWorkspace` URL for that tab gets refreshed to the new URL on the next refresh tick (we re-derive the URL list from `_tab_workspace` + current `cdp.list()` URLs per refresh).

**Switch (`w` picker → commit, `;` cycle, Super+Alt+; external cycle)**:

1. `_save_workspace_cursor(outgoing)`; seed `_pending_workspace_cursor` from incoming.
2. Write `state.currentWorkspace = new_id`.
3. `_restore_workspace_active(new_id)` validates the incoming workspace's remembered tab.
4. `_activate_workspace_remembered_tab` → `cdp.activate(remembered)` so chromium switches in lockstep, with the focus-restore dance + the `_pending_workspace_active_tab_id` MRU-lag gate (see the "Workspace switch" subsections below). Skipped when the workspace has no remembered tab.
5. Rebuild tree with `_suspend_dim_eval` on; the post-restore reeval is queued via `call_after_refresh`.

The view filter (loose leaves by `_tab_workspace`, saved groups by workspace id) still does the heavy lifting in step 5. The chromium activate adds one CDP call worth of latency on switches that have a remembered tab — without it, manual switches left chromium showing the outgoing workspace's tab until the user clicked something in the new tree.

### Boot behavior

bm reads `state.currentWorkspace` and renders that workspace. If the value is missing or points to a deleted workspace, fall back to `workspaces[0]`. The Workspace title row shows the current workspace's name (still accent + bold).

### UI / keybinds

| Key | Where | Action |
|---|---|---|
| `w` | anywhere | Workspace switcher (bottom-bar two-line picker, same shape as `s`). Header `Switch to:    (↑/↓)`, status row shows current workspace name. Always opens at index 0 — predictable cursor. `Enter` runs the switch flow above (saves outgoing workspace's cursor via `_save_workspace_cursor`, restores incoming workspace's remembered cursor + active tab; see "Per-workspace cursor memory" and "Per-workspace remembered active tab" below); `Esc` cancels. |
| `W` | anywhere | New workspace — preview-before-commit (same shape as `S`). Inserts a placeholder Workspace row in inline edit mode prefilled with `Workspace`. `Enter` creates the workspace (empty groups, empty open-tab list) and switches into it (saves outgoing cursor; new workspace has no remembered cursor / active so the rebuild lands on row 0 with no highlight); `Esc` rolls back. `[new workspace]` rides in the bottom-bar suffix slot. |
| `;` | anywhere | Cycle to the next workspace in `workspaces[]` (wraps). Instant — no picker UI. Same recovery dance as the `w` picker commit (flip `_initial_pair_done = False` so URL-pair seeding can re-run for the incoming workspace's saved rows; the session map and per-workspace cursor + active maps are preserved — see "Session map persists across workspace switches", "Per-workspace cursor memory", and "Per-workspace remembered active tab" below). Status `Switched to <name>`. Bound alongside the external Super+Alt+; binding so internal and external cycles share `_cycle_workspace_step`. |
| `r` | Workspace row | Rename current workspace via `store.rename_workspace(id, new_name)`. Existing inline-edit machinery; `[rename]` suffix. |
| `d` | Workspace row | Confirm prompt → destroy. Drops every saved tab where `workspace == id`, drops `state.openTabUrlsByWorkspace[id]`, removes the workspace from `workspaces[]`. If it was current, switch into the new `workspaces[0]` first (no chromium ops — it's a view filter). Blocked when only one workspace exists — status `Cannot delete the only workspace`. |

`r`/`d` on the Workspace row replace their tab/group meaning while the cursor is on that row — dispatch via the existing `_in_modal_state()` gates plus a `_WorkspaceMarker` data check.

**SIGRTMIN — external workspace cycle.** The TUI's `on_mount` installs a third asyncio signal handler alongside SIGUSR1/SIGUSR2 (cycle next/prev tab): SIGRTMIN fires `_cycle_workspace_step`. `bm workspace next` (the CLI subcommand bound to Super+Alt+;) dispatches this signal via `actions.send_workspace_cycle_signal()` — same `_signal_running_tui()` wrapper as the tab cycle, just a different signal number for routing. `;` (in-bm) and Super+Alt+; (global) both walk the same code path, so the user sees identical behavior regardless of which surface initiated the cycle.

### Destructive-action confirm prompt

Shared modal in the bottom `#search-tree` slot (`height: 1`). Layout: prompt text left-aligned at full opacity, `(y/N)` hint right-aligned at `_faded_fg(0.35)` via braille-blank padding (same approach as the save picker's `(↑/↓)`). `on_resize` re-renders so the alignment tracks terminal width.

| Cursor on | Prompt |
|---|---|
| Workspace row | `Delete workspace?    (y/N)` |
| Essentials leaf (saved row, `group == "Essentials"`) | `Delete essential?    (y/N)` |
| Group header | `Delete group?    (y/N)` |
| Saved row (non-Essentials) | `Delete saved tab?    (y/N)` |
| Loose live row | `Delete open tab?    (y/N)` |

`y` / `Y` commits → fires the destructive action, posts `Deleted <type>` status (3s timer), rebuilds. Anything else (`n`/`N`/`Esc`/other) cancels with no status — quiet rejection.

State plumbing: `BmApp._pending_confirm: dict | None` holds `{"kind": "delete_workspace"|"delete_saved"|"delete_group"|"close_live", "target_id": "..."}`. `_in_modal_state()` returns true while it's set, suppressing motion / action keys the same way the save picker does. `on_key`'s `y`/`n` branch calls `event.prevent_default()` so the focused Tree's widget bindings don't fire in parallel.

### Behavior changes vs. pre-workspace `d`

- **`d` on a paired saved row stops being layered.** Old: first press closed the live tab (no prompt), second press deleted the saved entry. New: single prompt → on `y`, close paired tab + delete saved entry in one shot. The "close-the-tab-keep-the-saved-entry" path lives entirely on `u` (unload), which keeps single-press, no-prompt behavior since it's recoverable from chromium history.
- **`d` on a group header becomes a binding.** Was unbound (empty groups disappeared as a side effect of deleting the last member). New: prompt `Delete group?` → on `y`, removes every saved tab in the group; header vanishes naturally on the next rebuild.

### Edge cases

- **Tab opened via `bm open <url>` from outside any workspace context** → tagged to current workspace.
- **Saved row in workspace X paired with tab T tagged X, user moves the saved row to workspace Y** → saved row now in Y, tab T still tagged X. While viewing Y, the saved row renders (its workspace) and pairs with T (session map). T is not shown as a loose leaf in Y (tag mismatch) and not in X either (no longer loose — paired). Consistent: the saved row "owns" T's visibility.
- **Saved row in workspace X, user-unsaves it via `d`** → row gone, T becomes loose. T's tag is still X. T appears as a loose leaf only in X.
- **Essentials** → an Essentials-paired tab still has a workspace tag (whatever was current when opened), but its visibility is decided by the Essentials row, which renders in every workspace. The tag becomes irrelevant for paired Essentials. If the user later removes the Essential entry, the now-loose tab pops back into its tag's workspace as a loose leaf.
- **Chromium tab opened directly (Ctrl+T in chromium)** → detected on the next 300ms tick → tagged to current workspace. Same as bm-opened tabs.

### CLI

| Invocation | What it does |
|---|---|
| `bm workspace list` | Print workspaces (id, name, current marker) as JSON |
| `bm workspace create <name>` | Append a new workspace to `workspaces[]` (empty groups, empty open-tab list) |
| `bm workspace rm <name>` | Destroy workspace + its saved tabs + its open-tab state. Refuses on the only remaining workspace. Non-interactive — no y/N. |
| `bm workspace switch <name>` | If a bm TUI is running, signal it to run the switch flow; else just update `state.currentWorkspace` so the next bm launch boots into it. |
| `bm save --workspace <name>` | Override the current-workspace default. `--group` still scopes within. |
| `bm list --workspace <name>` | Filter to a specific workspace. Default = current. |

## Save flows

Two keys, two intents — covered by the existing inline-edit / picker patterns so no new widget shapes are needed.

- **`s` — save / move via picker.** Bottom-bar two-line picker; header row reads `Save to:    (↑/↓)` (label and arrow hint both at `_faded_fg(0.35)`, hint right-aligned via braille-blank padding so it lands at the terminal's right edge with a one-cell breathing gap), status row shows the current group name on its own line. Width-zero first-paint case schedules `call_after_refresh(_update_search_tree)` so the hint snaps to the right edge once layout settles. The widget bumps to `height: 2` while the picker is open and reverts to `height: 1` for every other mode. `event.prevent_default()` is called for every key inside the picker (not just `event.stop()`) so the focused Tree's built-in `up`/`down` widget bindings don't drift the main cursor while ↑/↓ cycle picker entries. Group list = alphabetised user-created groups followed by `Essentials` pinned at the bottom and rendered as `[Essentials]` (brackets distinguish the special bucket from regular folders; the underlying value passed to the store is plain `Essentials`). The picker always opens at index 0 — no "remember last group" bias, predictable cursor every time. Live rows commit via `store.add_saved` which always appends a fresh row (uuid-keyed, no URL dedup), status `Saved Tab`; the returned `SavedTab.id` is captured and passed to `_claim_session_tab(new_saved_id, row.tab_id)` *before* `_load_all` so the new saved row pairs immediately even after the post-startup pair gate has closed. Saved rows commit via `store.move_saved(row.id, group)` (status `Moved to <group>` / `Already in <group>`) — the same picker doubles as a relocate UI, scoped by id so duplicate-URL siblings stay put.
- **`S` — save to a new group.** Preview-before-commit: a placeholder header (prefilled with `Group`, cursor at end) and the tab leaf are inserted into the tree in inline edit mode. **Nothing persists** until `Enter` — `Esc` rolls everything back cleanly. Hitting `Enter` without editing creates a group literally named `Group`; backspace + retype names it whatever you want. The placeholder is keyed under the `""` key in `_saved_nodes` so `_restore_edit_cursor` can find it again after Textual rebuilds the cursor on highlight events. The pending row's chromium tab id (if it's a live row) is added to `consumed_tab_ids` so it doesn't render twice (once under the placeholder, once as a loose leaf below the divider). On commit from a live row, the freshly-created `SavedTab.id` is captured from `store.add_saved`'s return and passed to `_claim_session_tab(created.id, row.tab_id)` the same way the `s` picker does so the new saved row pairs immediately.

`s`/`S` share one set of guards (`_in_modal_state`, `_in_help_mode`, `_in_search_mode`, "tab vs. saved row" cursor check). Only one save flow can be active at a time — the picker, an inline edit, and the new-group preview are mutually exclusive states. (Earlier `e` was a one-shot save-to-Essentials shortcut; that flow is now reachable as the bottom entry of the `s` picker, freeing `e` for inline URL edit — see "Inline edit modes".)

## Live-tab session rename

`r` on a live row writes a session-only override into `BmApp._live_titles[tab_id]` (keyed on the chromium tab id, not the URL — two tabs at the same URL each get their own override). The override only affects rendering (`_format_row` uses it via the `title=` kwarg); the underlying `Row.title` keeps the chromium-reported title so `_match` (search) keeps hitting the live page title. `_stable_sort_live` reaps stale entries each refresh tick when their tab id no longer exists, so closing a tab clears its override and a recycled id never inherits one. Never persisted — the override evaporates when bm exits.

## Persistent state split

| Lives in | Git-tracked? | Purpose |
|---|---|---|
| `files/config/omarchy/bm/saved-tabs.json` | Yes | Canonical saved-tab list — the whole point of the feature |
| `~/.config/bm/profile/` | No | Dedicated chromium profile (cookies, saved passwords, site permissions, history). Per-machine, not git-shared, but **preserved across `019` rollback** so the fast dev loop doesn't force re-login / re-block notifications every cycle. Wiped only on `020` rollback. |
| `~/.config/bm/state.json` | No | Local UI state. Active keys: `currentWorkspace` (uuid hex pointer into `workspaces[]` — last-viewed workspace, restored on bm boot) and `openTabUrlsByWorkspace` (`{workspace_id: [url, ...]}` — per-workspace URL list rebuilt every refresh tick from the in-memory `_tab_workspace` tag map; survives chromium session-restore so workspace tags re-attach by URL match). Reserved for future local state (collapsed groups, persisted filter, etc.). Disposable. |
| `~/.config/bm/bm.pid` | No | PID of the running bm TUI, written on mount and removed on shutdown (atexit + SIGHUP/SIGTERM). Read by `bm next`/`bm prev` to find the signal target. Stale PID files are unlinked on send failure. Disposable. |
| `~/.config/bm/chromium.pid` | No | PID of the bm-spawned chromium, written by `launcher._spawn` and removed by `close_chromium`. Read by `bm browser` (and `actions.raise_chromium`) so Super+Alt+L can dispatch hyprland focus by `pid:NNN` — class-based matching doesn't work because chromium ignores `--class=` on Wayland. Stale PIDs are detected via `os.kill(pid, 0)` and the file is unlinked. Disposable. |
| `~/.cache/bm/favicons/` | No | Regenerable image cache. Disposable. |

Only canonical, machine-shared data lives in the repo. Of the local-only paths, the chromium profile is stateful user data (auth, permissions) and is preserved across the fast rollback loop; everything else is disposable.

## Hyprland integration

Two patches — a global keybind block and a windowrule for the bm class.

**Global keybinds** (`~/.config/hypr/bindings.conf`, wrapped in `# --- BEGIN/END ko komarchy bm-tool bindings ---` markers so rollback can strip cleanly):

```
bindd = SUPER ALT, H,         bm sidebar,        exec, $HOME/.local/bin/bm focus
bindd = SUPER ALT, J,         bm next tab,       exec, $HOME/.local/bin/bm next
bindd = SUPER ALT, K,         bm prev tab,       exec, $HOME/.local/bin/bm prev
bindd = SUPER ALT, L,         focus browser,     exec, $HOME/.local/bin/bm browser
bindd = SUPER ALT, semicolon, bm next workspace, exec, $HOME/.local/bin/bm workspace next
```

Vim-key leader block plus `;` as the right-of-`L` extension for workspace cycling. `Super+Alt` is chosen because these keys are unbound there at every layer — stock omarchy uses `Super+J/K/L` (single-Super, no Alt) for window-split / show-keybinds / toggle-layout, which stay intact. `Super+Alt+arrows` are *not* free (omarchy uses them for window-to-group movement and resize), so we deliberately bind the vim keys.

`bindd` (not `bind`) — the `d` variant carries a description that shows up in keybind cheatsheets (including `Super+K`, the stock "Show key bindings" popup). Absolute paths are used because hyprland's exec PATH doesn't include `~/.local/bin` in default omarchy setups — the keybinds would otherwise silently fail with "command not found."

**What each bind does** — logic lives in the bash wrapper at `files/local/bin/bm`. Each binding follows a **two-press model** for the cycle keys: the first press lands focus on the right surface, the second press triggers the action. Keeps "I just want to come back to bm/chromium" from accidentally cycling past the user's current state.

- **H — focus bm**: focuses the running bm window via `cmd_focus` (process-ancestry lookup) — `hyprctl dispatch focuswindow address:NNN` auto-switches the user to bm's hyprland workspace as a side effect. Spawns a new sidebar ghostty if no bm is running.
- **J / K — cycle next/prev tab, two-press**: if **either bm or chromium is currently focused** (i.e. the user is already in the bm context), signals the running TUI (SIGUSR1/SIGUSR2) to step the cursor + activate the next row in-process. If neither is focused, the keypress only **focuses chromium** (no cycle) — the user just wanted to land on chromium without their cursor skipping past their current tab. When bm isn't running at all, falls through to `cmd_focus` to spawn the whole stack.
- **L — focus chromium**: `bm browser`, a thin CLI wrapper that reads `~/.config/bm/chromium.pid` (written by `launcher._spawn` at chromium-spawn time) and runs `hyprctl dispatch focuswindow pid:NNN`. Symmetric counterpart to H for the two-pane sidebar layout. PID-based dispatch is required because chromium on Wayland ignores `--class=`, so class-based hyprctl matching can't distinguish the bm chromium from any other chromium window the user has running. Stale PID handling (chromium died without bm cleanup) silently no-ops and drops the file. When bm isn't running, falls through to `cmd_focus` to spawn the stack.
- **; — cycle next workspace, two-press**: if **either bm or the bm-launched chromium is currently focused** (i.e. the user is already in the bm context), signals the running TUI (SIGRTMIN) to advance `_current_workspace` in-process. If neither is focused, the keypress only focuses bm (no cycle) — pressing it from another app/workspace lands the user on bm first; the second press cycles. Treating chromium-focused the same as bm-focused mirrors the J/K cycle model and stops the user from getting yanked off chromium just to advance workspaces. When bm isn't running, falls through to `cmd_focus`. Mirrors the in-bm `;` keybind.

**Two-press model state checks.** `is_bm_running` reads `bm.pid` and `kill -0`s it. `is_bm_focused` reads `hyprctl activewindow -j` and matches `class == "com.ko.bm"`. `is_chromium_focused` reads the same and matches `pid == <chromium.pid contents>`. PID-based for chromium because we can't distinguish bm chromium from a non-bm chromium by class on Wayland.

**External cycle architecture (signal-based).** Super+Alt+J/K and Super+Alt+; are **remote triggers for the TUI's internal motion**, not CLIs that reconstruct tree state. Three signals, three handlers, one `_signal_running_tui()` wrapper on the CLI side:

| Signal | CLI subcommand | TUI handler |
|---|---|---|
| SIGUSR1 | `bm next` | `_cycle_step(+1)` — cursor + activate next row |
| SIGUSR2 | `bm prev` | `_cycle_step(-1)` — cursor + activate prev row |
| SIGRTMIN | `bm workspace next` | `_cycle_workspace_step()` — advance current workspace |

Division of labor:

- **TUI side.** On startup, `BmApp.on_mount` writes its PID to `~/.config/bm/bm.pid` and installs asyncio signal handlers for all three signals via `loop.add_signal_handler(...)`. `run_tui`'s atexit + SIGHUP/SIGTERM handlers remove the PID file so the next cycle press doesn't signal a dead process (or, worse, a reused PID). When a signal arrives, the matching handler runs on the event-loop thread (safe to touch Textual state). For tab cycle: `_cycle_step(direction)` walks `tree.action_cursor_down()` / `_up()` past any `_SpacerMarker` / `_WorkspaceMarker` / `_GroupMarker`, wraps at the tree edges, then activates the resulting row via `_peek_row` — same path used by `p` / preview mode, so the capture-active-window / reassert-focus dance is inherited. Landing on an Essential row moves the cursor but doesn't touch chromium (Essentials have no URLs). For workspace cycle: `_cycle_workspace_step()` saves the outgoing workspace's cursor via `_save_workspace_cursor`, advances `_current_workspace` in `workspaces[]`, seeds `_pending_workspace_cursor` from the incoming workspace's slot (or `{}` to signal "switch with no memory" — triggers the cursor-line reset to 0 in `_rebuild_tree`), runs `_restore_workspace_active(target_id)` to validate the incoming workspace's remembered active tab, then `_activate_workspace_remembered_tab()` to drive chromium to that tab via `cdp.activate` (with the focus-restore dance + `_pending_workspace_active_tab_id` MRU-lag gate), flips `_initial_pair_done = False` so the next rebuild's URL-pair seed runs for the incoming workspace's saved rows, persists via `store.set_current_workspace`, and rebuilds the tree (with `_suspend_dim_eval` on, resumed via the `call_after_refresh _resume_dim_eval` callback after `_restore_cursor`). The session map (`_saved_session_tab_id`), per-workspace cursor map (`_workspace_cursors`), and per-workspace remembered-active map (`_workspace_active_tab`) are **all** preserved across the cycle — see the "Session map persists across workspace switches", "Per-workspace cursor memory", and "Per-workspace remembered active tab" subsections below for the rationale on each.
- **CLI side.** `actions.send_cycle_signal(direction)` and `actions.send_workspace_cycle_signal()` both call `_signal_running_tui(sig)` which reads the PID file and `os.kill(pid, sig)`. That's the entire CLI contribution — no CDP calls, no saved-tab reconstruction, no state writes. Stale PID files (TUI died without cleanup) are detected via `ProcessLookupError` and unlinked so the next press is cheap.

The TUI is the single source of truth for tree ordering and activation. One benefit: the cycle automatically includes whatever the TUI chooses to render (currently Essentials + Saved rows + loose leaves) without the CLI having to model the same structure. Another: no `state.json` bookkeeping — the TUI's in-memory cursor is the cycle anchor.

**Cursor visibility during external cycle.** `_cycle_step` keeps `cursor_active = True` so the hover dim lands on whichever row the cycle stopped at — a visible pointer in the tree as the user steps through from another app. Each cycle step lands the cursor on the row that just became the active tab; the `ACTIVE_DIM_FLASH_S` on-arrival flash (see "Active-tab highlight") is suppressed here because `_reevaluate_active_dim` sees `active_changed=True` and gates the flash on pure cursor motion — cycle steps are activations, not user-driven landings, so they paint directly to full `color11` without the intermediate dim blip.

**Stable live-tab order.** Chromium's `/json/list` returns tabs in MRU order on most builds, so every `cdp.activate` (from preview, external cycle, or Enter) would reshuffle the loose live leaves — the tab you just jumped to would pop to the top, dragging neighbors around. `_stable_sort_live` fixes this by maintaining `self._live_order: list[str]` of tab ids in first-seen order: each refresh drops ids that no longer exist, appends newly-seen ids to the end, then returns `cdp.Tab`s in that order. Only *position* is stabilized — titles and URLs still update live when the user navigates within a tab. The first entry from CDP's raw (MRU-ordered) response is captured *before* sorting and used for the active-tab follow (see "Follow chromium's focused tab"), so MRU-driven reshuffling doesn't contaminate the tree order while still feeding the highlight.

**Diff-guarded refresh.** `_refresh_live` fires every `REFRESH_SECONDS` (300 ms), but the tree only rebuilds when something visible actually changed — a `_tabs_differ` helper compares `(id, url, title)` tuples between old and new `self._live`, and an `active_tab_id` inequality check covers manual chromium tab switches. Most 300 ms ticks are pure polling: two localhost HTTP calls (~2-5 ms total) and zero rendering work. Cost of the faster cadence stays below noise, while active-tab follow / open / close events propagate to the UI in ≤300 ms worst case.

**Cursor survives rebuilds.** When `_rebuild_tree` does fire, `tree.clear()` resets the cursor to line 0 — without preservation, both local j/k navigation and the external-cycle cursor would be thrown away on every rebuild. `_rebuild_tree` therefore captures the cursor's current row identity — `url`, `kind`, plus `id` (saved row) and `tab_id` (live row) — before clearing, then schedules `_restore_cursor` via `call_after_refresh` to re-move the cursor onto the matching leaf (loose live tabs live at `tree.root.children`; saved tabs nest under `self._saved_nodes[group].children`). `_restore_cursor` matches saved rows by `SavedTab.id` and live rows by chromium `tab_id` — URL alone would re-seat the cursor on a sibling when duplicate URLs exist (e.g. editing the second of two saved `yahoo.com` rows would jump to the first after commit). URL is kept as a fallback when id/tab_id are absent. The `call_after_refresh` indirection is required: right after `tree.clear()` + `add_leaf`, Textual hasn't laid out the new TreeNodes yet — each leaf's `line` attribute is still -1, so moving the cursor silently snaps it back to line 0. Deferring to the next refresh tick means layout has computed line numbers and the move actually lands on the right row. If the row no longer resolves (tab closed, saved row removed, filter excluded it), the cursor stays at 0 as a fallback.

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

**Sidebar resize on every bm launch.** `cmd_interactive` (the path that runs after the new ghostty has spawned bm-py) also calls `shrink_to_sidebar` unconditionally, regardless of whether bm spawned chromium itself or chromium was already up. Earlier this was gated on `! cdp_up`, so bm opened at the default 50/50 dwindle tile when chromium was already running (session-restored, leftover from a crash, or manually launched). `cdp_up == True` already implies chromium exists, so the shrink is always appropriate at that point.

The terminal address fed to `shrink_to_sidebar` is resolved by `self_ghostty_address` — walks the bash script's process ancestry (`$$` → ppid chain) until it hits a `ghostty` process, then looks up that PID's hyprland client. PID-based instead of `hyprctl activewindow` because the previous `active_window_address` approach was racy: when bm was spawned via `cmd_focus`, the just-created ghostty hadn't necessarily grabbed focus yet, so activewindow could report chromium (or the launcher app), and `shrink_to_sidebar` would either resize the wrong window or no-op on an empty address. PID-based is deterministic regardless of focus state. Brief 5×50ms poll loop handles the case where ghostty's window was just mapped and hyprctl hasn't yet picked up the client.

Flow: `Super+Alt+H` → focus jumps to `bm` (or launches it as a left-edge sidebar) → vim-navigate → Enter or Esc → focus returns to chromium. `Super+Alt+L` sends you back to chromium any time. `Super+Alt+J/K` flip through chromium tabs from anywhere — terminal, editor, anything — first press lands on chromium, second press cycles. `Super+Alt+;` cycles workspaces with the same two-press model — first press from outside the bm/chromium pair focuses bm; pressing it while either bm or the bm chromium has focus cycles in place (no focus shuffle, since the user is already looking at the right surface). Super+1-9, Super+H/J/K/L (single-Super, no Alt), and all other omarchy prefixes stay free for the rest of your workflow.

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

**Workspaces feature ships inside group `019` — no new group.** `019-00110-bms-app.sh` already runs `uv tool install --force --from "$PKG_SRC" bm`, so updating the bundled source under `files/local/share/bm/` and re-running the `019` rollback + re-migrate cycle picks up the new code cleanly. Local-state extensions (`currentWorkspace`, `openTabUrlsByWorkspace` in `state.json`) are wiped by `019-00111` rollback alongside the existing keys; the v1→v2 schema bump runs Python-side on first `store.load_saved`, so no script-level data migration is needed. Full clean-slate testing of the schema migration is already covered by `020-00113` rollback wiping `~/.config/bm/` and `saved-tabs.json`.

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
| `019-00110-bms-app.sh` | `uv tool install --force` the Textual `bm` package — picks up source changes (including the workspaces feature) on every re-migrate. |
| `019-00111-bms-bin.sh` | Copy the `bm` launcher to `~/.local/bin/bm`, the dedicated Ghostty config to `~/.config/ghostty/bm.conf`, and seed `~/.config/omarchy/bm/saved-tabs.json` (preserving any existing one) |
| `019-00112-bms-hyp.sh` | Append Super+Alt+hjkl leader block and marker-comment windowrules block to Hyprland config |
| `020-00113-bmc-stb.sh` | Final-cleanup arming script (no-op marker). Reports saved-tabs.json and `~/.config/bm/` (chromium profile) presence; the real work happens on rollback. |

**Rollback behavior** (important for the `rollback → migrate` test cycle):

- `019-00110` rollback runs `uv cache clean bm` after uninstalling so subsequent installs don't hit a stale wheel cache
- `019-00111` rollback removes the launcher, ghostty config, ephemeral bm UI state (`bm.pid`, `state.json` — including the `currentWorkspace` and `openTabUrlsByWorkspace` keys), and `~/.cache/bm/` (favicon cache), but **preserves** `~/.config/omarchy/bm/saved-tabs.json` **and `~/.config/bm/profile/`** — the chromium profile holds auth cookies, saved passwords, and site permissions (e.g. notification blocks), so treating it as disposable forced re-login and re-blocking every dev cycle. Kept alongside saved-tabs.json on the fast-loop side
- `020-00113` rollback removes `~/.config/omarchy/bm/saved-tabs.json` (and `rmdir`s the parent dir if empty) **plus `~/.config/bm/` in full** (chromium profile + any remaining UI state) — use this when you actually want a fresh-user clean slate (rollback both groups via `[Rollback All]`, then re-migrate). This is also how you exercise the v1→v2 schema migration end-to-end: wipe, re-migrate, then run `bm` against either an empty saved-tabs.json or one you've seeded with v1-shape data, and watch `store.load_saved` upgrade it on first read.

**Interaction with `018-00073-bkm-als.sh`**: the existing migration that installs `bm()` is not edited. Fresh installs run it, get `bm()` in `.bashrc`, then `019-00108-bmd-ren.sh` immediately converts it to `bmd()`. Already-migrated users just run the 019 rename. The rollback of `019-00108-bmd-ren.sh` restores `bm()` → consistent with the original 018 migration.

Chromium is not installed by a migration — omarchy ships with it, so `bm` relies on that. If you wipe omarchy's defaults, reinstall `chromium` manually before running these.

## Phased rollout

- **Phase 1** (shipped) — Textual TUI with open-or-switch, saved tabs with groups (data-driven Essentials section that any user-saved `group: "Essentials"` row populates), **per-row stable `id` (uuid hex)** as the saved-tab identity (so duplicate URLs are allowed anywhere — across groups *and* within a single group; `add_saved` always appends, never dedupes; `remove_saved` / `move_saved` / `update_url` / `rename_saved` all key on `id`; pre-`id` `saved-tabs.json` files are backfilled on first read and persisted back), loose-leaf rendering for open-but-unsaved tabs (with **session-based saved↔live pairing** that locks each saved row to the chromium tab id it was activated into for the rest of the session — survives in-tab navigation like clicking a link or following a redirect; URL-exact and loose-key pairing only run on the first rebuild to seed startup state, after which only explicit user actions establish new pairings, so loose tabs the user navigates to a saved URL stay loose instead of getting silently absorbed), **search-key-aware `cdp._urls_match`** (host + path + agreement on `q` / `query` / `search` keys; preserves Gmail-style loose match while keeping `?q=ibm+5150` and `?q=javascript` as distinct tabs), **`_activate_saved` always opens a fresh chromium tab** for unpaired saved rows (instead of `find_or_switch`), so clicking a saved row never adopts a coincidentally-matching loose tab, Nerd-Font glyphs on each row, Workspace title row with an unconditional `_SpacerMarker` below it for stable layout across empty/groups-only/essentials states, theme-aware per-row color tiers + hover dim + tab_id-based active-tab highlight that follows manual chromium tab switches within 300 ms (with the **bm cursor following the highlight** on close-driven and external-click shifts, parking `cursor_active` during the rebuild to suppress hover-dim flash), **unpaired-saved dim** (saved rows whose tab_id is empty render with a 0.4 blend toward bg so dormant entries are obvious at a glance), **on-arrival flash-dim on the active row** (180 ms blend-and-restore fired only when the cursor *moves onto* an already-active row, suppressed when the row *becomes* active via activation; suppressed entirely in preview for Row nodes), Hyprland tiling, `bm` CLI subcommands (`open`, `save`, `list`, `rm`, `next`, `prev`) for scripted use, signal-based Super+Alt+J/K cycle that walks every tree row (Essentials + Saved + loose live) from any app, diff-guarded 300 ms refresh tick, **inline rename** for tabs (saved → persisted, live → session-only override) and group headers (`store.rename_group` rewrites every member tab), **inline URL edit** for saved rows (`e` — `store.update_url(saved_id, new_url)`, `[edit url]` marker; no session-pair migration needed since `_saved_session_tab_id` keys on `SavedTab.id` which is stable across the URL change), terminal-style inverted cursor + per-character motion + **word motion** (`Ctrl+Left/Right`) + **word delete** (`Ctrl+Backspace/Delete`) + **clear buffer** (`Ctrl+Shift+Backspace`) + viewport scroll for overflow, **two-line `s` save/move picker** with `Save to:` / `(↑/↓)` header and bracketed `[Essentials]` pinned at the bottom of the group list (always opens at index 0 — predictable cursor, no last-group bias), live rows save via `store.add_saved`, saved rows move via `store.move_saved`, `_claim_session_tab` runs on commit so newly-saved rows pair instantly, **`S` preview-before-commit new-group flow**, **`d` layered close-then-delete** (loose live → close tab; saved + paired → close tab keeping saved entry; saved + unpaired → remove from json), **`u` unload tab** (`d` minus the second-press delete: closes the live/paired tab, no-op on unpaired saved rows so it can never destroy a json entry), **`R` reload saved tab** (close paired tab + drop session claim, open fresh chromium tab at the canonical saved URL, re-claim — undoes in-tab URL drift; live rows rejected), **`q` immediate quit** (separated from Esc's tier ladder), `[rename]` / `[edit url]` / `[new group]` / `[preview]` status-bar markers, **preview-mode cursor restrictions** (`j`/`k`/`J`/`K` only land on tab rows and wrap at edges like the external cycle; `g`/`G`/`Ctrl+D`/`Ctrl+U` skip non-tabs without wrapping; hover-dim suppressed on Row nodes since the peek's `color11` transition is the motion cue), and Tree binding-leak gates that keep stray keystrokes from scrolling the tree or double-activating the renamed tab on commit.
- **Phase 1.5** (in flight, ships inside the existing migration group `019`) — **multi-workspace support**: schema v2 (`workspaces[]` + per-tab `workspace` field, `version` bump, v1→v2 auto-migration in `store.load_saved`), per-tab workspace tag (`_tab_workspace: dict[tab_id, workspace_id]`) with URL-based persistence (`state.openTabUrlsByWorkspace`) for cross-restart re-tagging via chromium session-restore, `w` switcher / `W` new-workspace preview / `;` instant cycle / `r`-on-Workspace-row rename / `d`-on-Workspace-row destroy keybinds, switch-as-view-filter (no chromium close-and-reopen — the heavy lifting is just the loose-leaf filter; the workspace switch additionally issues one `cdp.activate` to sync chromium to the incoming workspace's remembered tab — see "Workspace switch syncs chromium" below), boot-into-last-viewed-workspace, **shared destructive-action confirm prompt** (`Delete <type>?    (y/N)` in the bottom bar) routing every `d` invocation through the same y/N modal, single-step `d` on saved rows (replaces the layered "first close, then delete" with single-prompt-then-destroy; the close-only path lives entirely on `u` now), `d` on group headers as a real action (was unbound), **PID-based chromium focus** (`~/.config/bm/chromium.pid` + `bm browser` CLI; chromium ignores `--class=` on Wayland so class-based hyprctl matching can't isolate the bm chromium), **SIGRTMIN external workspace cycle** (`bm workspace next` signals the TUI; bound to Super+Alt+;), **two-press global keybind model** for the cycle keys (J/K/; — first press lands focus on the right surface, second press cycles; `;` treats both bm and the bm-launched chromium as "in context" so cycling from chromium doesn't yank focus to the sidebar), **spawn-bm-if-not-running fallback** for J/K/L/; (any of those keybinds opens bm + chromium when nothing's running), **PID-based terminal lookup** for `shrink_to_sidebar` (replaces racy `hyprctl activewindow` resolution that resized the wrong window when bm had just been spawned), and unconditional sidebar resize on every bm launch (not just when bm spawned chromium itself). **Saved↔live pairing survives workspace switches**: removed the `_saved_session_tab_id.clear()` calls from the four workspace-mutation paths (cycle / picker switch / new / delete-with-recovery) so a saved row the user has activated stays paired regardless of how many workspaces they cycle through — the prior `.clear()` left every saved row in the original workspace unpaired after a round trip, and `_activate_saved`'s unpaired branch always opens a fresh chromium tab, accumulating duplicates. **`_restore_cursor` matches paired saved rows by tab_id** as a saved-walk fallback, so the chromium-focus follow finds a paired saved row even when its URL has drifted from the canonical saved entry (Workday OAuth redirect, Angular SPA route changes, Google Sheets gid drift). **Per-workspace cursor memory** (`_workspace_cursors: dict[workspace_id, {url, kind, saved_id, tab_id}]`) snapshots the cursor on every workspace exit and restores it on re-entry via `_pending_workspace_cursor`, so each workspace remembers where the user was last; first-visit workspaces explicitly reset `cursor_line = 0` (Textual's `tree.clear()` retains the previous numeric cursor index, which would otherwise drop the cursor mid-tree on a workspace with no memory). **Per-workspace remembered active tab** (`_workspace_active_tab: dict[workspace_id, tab_id]`) tracks each workspace's last-active row so the yellow highlight reappears on switch back; render path keys on `_displayed_active_tab_id()` (per-workspace) rather than the global `_active_tab_id` (chromium focus). **Workspace switch syncs chromium**: `_activate_workspace_remembered_tab` issues `cdp.activate(remembered)` after `_restore_workspace_active` validates, with the same focus-restore dance as `_peek_row` so chromium's BringToFront doesn't strand keyboard focus on the wrong window. Without this, manual switches only flipped bm's view; chromium kept showing the outgoing workspace's tab. Two safeguards on the chromium-driven path: `_pending_workspace_active_tab_id` gates `_refresh_live`'s `active_changed` processing while chromium's `/json/list` MRU is still trailing the activate ack (without the gate, the cross-workspace follow chases the lagging focused tab and flips back to the outgoing workspace, then forward again — visible as a flicker), and `FolderTree._suspend_dim_eval` short-circuits `_reevaluate_active_dim` for the duration of `_rebuild_tree` (Textual's base Tree fires `watch_cursor_line` mid-build via `cursor_line = cursor_node._line` reassignment after the line cache rebuild, with the cursor sitting on whatever transient row line N points to in the half-built new tree — eats the `active_changed` signal and misfires the dim-flash on landing); a final `_resume_dim_eval` queued via `call_after_refresh` (after `_reset_cursor` / `_restore_cursor`) clears the flag and runs one observation against the settled cursor + active state. **Cross-workspace chromium-focus follow**: `_workspace_for_tab()` decides which workspace renders a given chromium tab (Essentials = current; non-Essentials saved = its workspace; loose = its `_tab_workspace` tag); when chromium focuses a tab in a workspace other than the one bm is showing, `_refresh_live` auto-switches bm to follow (saves outgoing cursor + active, seeds pending-cursor with the active tab so the cursor lands on it in the new view, posts `Switched to <name>`). Boot-tick guarded so the first refresh doesn't override `state.currentWorkspace`. **`t` new tab** — Ctrl+T equivalent from inside bm: opens a fresh chromium tab on `chrome://newtab/` via `cdp.new_tab`, raises chromium so the user lands on the new-tab page's search box, refresh-before-mark-active so the new tab id is in `self._live` before the rebuild and `_remember_active_for_current_workspace` records it as the workspace's active row. Status `New Tab`. CLI: `bm workspace list|create|rm|switch|next <name>`, `bm browser`, `--workspace` flag on `save`/`list`. Pure code update — `019-00110-bms-app.sh`'s existing `uv tool install --force` reinstalls the package with the new source on every re-migrate; v1→v2 schema bump runs Python-side on first `store.load_saved`.
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
