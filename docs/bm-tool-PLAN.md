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
- Chromium closed by the user (CDP stops responding) → `_refresh_live` sees CDP go down and calls `App.exit()`. The CDP-up/down probe runs on every 3s tick regardless of mode — only the *tree rebuild* is suppressed in help/search (to avoid clobbering the help screen or an active filter), so closing chromium from any mode tears bm down within the refresh window.

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
| `bm next` | Cycle forward through **saved tabs** and activate the matching chromium tab, preserving current window focus. Silent no-op if chromium isn't running or fewer than two saved tabs. Bound to Hyprland's Super+Alt+J. |
| `bm prev` | Cycle backward through saved tabs, preserving focus. Bound to Super+Alt+K. |

The Textual TUI and the subcommands both drive the same Python module internally — no duplicated logic. Most CLI subcommands go through `launcher.ensure_up()`, so if chromium was closed between invocations they transparently respawn it (with the session-restore flow above) before running. The exception is `bm next` / `bm prev`: those use `cdp.is_up()` (a passive probe) and silently no-op when chromium isn't running, because auto-launching chromium from a tab-cycle keypress would be surprising — bm+chromium are paired anyway, so "chromium gone" means there's nothing meaningful to cycle.

## Components

| Path | Role |
|---|---|
| `files/local/bin/bm` | Entry point — runs TUI inline (no args) or handles subcommands (`focus`, `open`, `save`, `list`, `rm`) |
| `files/local/share/bm/` | Python package (pyproject.toml + `bm/` module) |
| `files/config/omarchy/bm/saved-tabs.json` | Git-tracked saved-tab list, shared across machines |
| `~/.config/bm/state.json` | Local UI state (cursor, collapsed groups), not in git |
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

- **`#tree`** — main list (`height: 1fr`). Top-level nodes are `▾ Open Tabs (N)` followed by one `▾ Saved: <group> (N)` node per group. Groups are collapsible. This is the only focusable widget.
- **`#search-tree`** — single-row leaf at the bottom (`height: 1`). Multiplexed across three primary uses with priority: **active search > ephemeral status > committed filter > empty**, plus a **preview-mode suffix** that rides alongside whichever primary is showing, **except** during active search (would fight the blinking prompt) and during an ephemeral status message (the tag would push the message around; `_blink_cursor` re-renders when the status times out and the suffix comes back).
  - Active search: `/foo█` (blinking cursor while typing)
  - Ephemeral status: transient notification like `Saved Tab`, `Removed Tab`, `Already saved`, or `Failed to activate (…)`, rendered at **0.65 foreground opacity** (readable but clearly non-focal, via `_faded_fg(0.65)`) and auto-cleared after `STATUS_DURATION` (3s). Kept deliberately short — no title embedded in the message, since the cursor already shows which row was acted on.
  - Committed filter: `/foo` (no cursor) once the user hits enter on a search
  - Preview suffix: `[preview]` rendered at **0.35 foreground opacity** via `_faded_fg(0.35)` — noticeably dimmer than the 0.65 status tier, because it's a persistent mode marker that should sit quietly at the edge rather than compete with transient messages on the left. **Right-aligned** at the opposite end of the row; primary content stays left-aligned with the one-cell braille-blank inset, and braille-blank padding between them is computed from `search_tree.size.width` to push the suffix to the edge. `on_resize` re-renders so the alignment tracks terminal-width changes. On the one call that flips `display:False→True` the widget hasn't been laid out yet (`size.width == 0`); that case falls back to a minimum gap and schedules `call_after_refresh(self._update_search_tree)` so the suffix snaps to the right edge on the next paint instead of visibly sliding over from the left.
  - Hidden entirely when none of the above applies — the main tree fills the viewport

```
╭─ bm ──────────────────────────────────────────╮
│ ▾ Open Tabs (3)                               │
│   [] GitHub – claude-code/issues              │
│   [] Hyprland Wiki – Window Rules             │
│   [] Hacker News                              │
│                                               │
│ ▾ Saved: Work (5)                             │
│   [] Azure Portal                             │
│   [] Jira – TEAM board                        │
│   ...                                         │
│ ▸ Saved: Personal (8)                         │
│ ▸ Saved: Reading (12)                         │
├───────────────────────────────────────────────┤
│ /github█                                      │  ← #search-tree (search / status / filter)
╰───────────────────────────────────────────────╯
```

Each row shows the favicon glyph (phase 1) or Kitty-graphics image (phase 2), followed by the title. Groups are collapsible sections in the saved-tabs half.

## Keybinds (inside the TUI)

All tab-navigation logic lives inside `bm` — the global keybind just gets you there.

| Key | Action |
|---|---|
| `j` / `k` (or `↓` / `↑`, or `Shift+j` / `Shift+k` while searching) | Move down/up through tab list |
| `h` / `l` (or `←` / `→`, or `Shift+h` / `Shift+l` while searching) | Collapse/expand group, or switch section (Open ↔ Saved) |
| `g` / `G` (or `Home` / `End`) | Jump to top / bottom |
| `Ctrl+d` / `Ctrl+u` (or `PgDn` / `PgUp`) | Half page down / up |
| `⏎` | Activate selected tab (also raises chromium, returns focus to browser) |
| `o` | Open-or-switch the selected row (works on live and saved rows — saved rows find-or-create a chromium tab at that URL) |
| `s` | Save the selected row to `saved-tabs.json` (no-op status "Already saved" if the cursor is already on a saved row) |
| `d` | Delete selected saved tab |
| `r` | Rename selected saved tab |
| `/` | Filter search (narrows both sections; text appears in the bottom `#search-tree` leaf) |
| `n` / `N` | Next / previous search match |
| `p` | Peek — activate the selected tab in chromium without raising the chromium window (one-shot; keyboard focus stays in bm) |
| `P` | Toggle auto-preview mode — every cursor move auto-peeks. `[preview]` shows in the status line while on |
| `?` | Toggle help — renders a "Keybindings" reference inline in the main tree (see below) |
| `q` or `Esc` | Close: first press in search clears it; otherwise closes chromium and exits the TUI |

### Help screen (`?`)

Tap `?` to swap the tree contents for a keybind reference. Renders **inline in the same Tree** (not a separate widget) so the window's transparency is preserved — a prior Static-based layout painted the area opaque with `$background` regardless of CSS, which is why we stayed in the Tree.

Layout:

- **Title row** `Keybindings` in **bold accent** color.
- **Spacer row** — a single Braille-blank leaf.
- **Key column** right-aligned within a fixed width, padded with **Braille Pattern Blank (U+2800)**. Tree strips leading ASCII/Unicode whitespace from labels but U+2800 isn't classified as whitespace, so the padding survives and the column aligns cleanly.
- **Left margin** — one Braille-blank cell so the whole block has breathing room from the window edge (matches the status line's inset).
- **Key color** = the theme's `accent`, pulled from `~/.config/omarchy/current/theme/colors.toml`. One per-theme exception: **Osaka Jade** uses `color6` (`#2DD5B7`) because its accent is green and a cyan highlight reads better there. Detected via `~/.config/omarchy/current/theme.name`.

Motion keys (`j/k`, arrows, `g/G`, `Ctrl+d/u`, `h/l`) keep working while help is visible so you can scroll the list. Modification actions (`Enter`, `o`, `s`, `d`, `r`) are short-circuited in help mode. `?` toggles out; `Esc`/`q` also closes the TUI as usual.

**Cursor floor in help mode.** Opening help parks the cursor on the blank spacer row (tree index 1), not the title. `action_cursor_up`, `action_half_page_up`, and `action_jump_top` clamp to that same floor so `k` / `Ctrl+U` / `g` can never land on row 0 (the `Keybindings` title). Row 1 is a braille-blank leaf, so the accent cursor is invisible there — help opens looking "unselected" and the title stays decorative.

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

**Render-path color.** The `●` is the raw omarchy `accent` hex, pulled from `self._omarchy_colors` and passed through Rich markup — same pattern as the faded-foreground status label, since Textual's `$accent` variable doesn't parse as a Rich style.

## Favicons

**Phase 1 (shipped):** every row renders a Nerd Font globe glyph — no network calls on the render path. The earlier prototype that fetched favicons synchronously on every row/refresh added up to 20s of blocking per first paint, so the fetch was removed entirely.

**Phase 2 (planned):** background worker fetches and caches favicon PNGs, then the TUI paints them via the Kitty graphics protocol (Ghostty supports it). Fetch pattern to reuse:

- **Live tabs** — CDP's `/json/list` response already includes `faviconUrl` per tab.
- **Saved tabs** — reuse `files/local/bin/appgroup-create-webapp:47-50`: try `https://{domain}/apple-touch-icon.png`, fall back to `https://www.google.com/s2/favicons?domain={domain}&sz=128`.

**Caching:** `~/.cache/bm/favicons/{domain}.png`. Never git-tracked — trivially reconstructed. Already wired up in `bm.favicon`; just not called from the render path yet.

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
| `~/.config/bm/state.json` | No | UI ephemera — last cursor position, collapsed groups |
| `~/.cache/bm/favicons/` | No | Regenerable image cache |

Only canonical, machine-shared data lives in the repo. Everything else is local and disposable.

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
- **J / K — cycle *saved* tabs without moving focus**: steps forward/back through the user's `saved-tabs.json` and activates the matching chromium tab (or opens a new one at that URL if it isn't already open). Your keyboard focus stays on whatever app you're in. Implemented by `actions.cycle_saved_tab(direction)` which delegates to `open_or_switch(url, raise_window=False)` per step, wrapping the call in the same capture-active-window / reassert-focus dance preview mode uses (sync call + 80 ms delayed retry). Silent no-op when chromium isn't running (`cdp.is_up()` probe before anything else) or fewer than two saved tabs exist — no auto-launch, since bm+chromium are paired and "chromium gone" means "nothing meaningful to cycle."
- **L — focus chromium**: `hyprctl dispatch focuswindow class:chromium`. Symmetric counterpart to H for the two-pane sidebar layout.

**Tab-order semantics (J/K).** Order is defined by `saved-tabs.json`'s file order — that's the canonical, user-editable sequence, so no separate cache is needed. `cycle_saved_tab` stores **only the URL** of the last cycled-to tab in `~/.config/bm/state.json` under `tab_cycle_url`; on each press it finds that URL's position in the current saved list and steps ±1 from there. Consequences:

- Edits to `saved-tabs.json` (reorder, rename, add) are picked up immediately without any cache-invalidation logic.
- If the saved tab we last landed on is **removed**, the URL won't match anything on the next press — we treat that as a fresh start and seed *just before the edge* so the next step lands cleanly on `saved[0]` (for J) or `saved[-1]` (for K).
- Manual tab switches in chromium (click, Ctrl+Tab) aren't observed — the URL cursor stays "where bm last put it." The user can always `Super+Alt+H` into bm and pick a tab explicitly to resync.

**TUI cursor follows the keybind.** When the TUI is visible and the user presses `Super+Alt+J/K` globally, the cursor snaps to the saved leaf that was just activated in chromium. Implemented in `_sync_cycle_cursor`, which piggybacks on the existing `_blink_cursor` 500 ms interval: on each tick it reads `state.json`, compares the current `tab_cycle_url` against the last one it snapped to (`_last_synced_cycle_url`), and — if it has changed — schedules the actual `move_cursor` via `call_after_refresh` (in `_select_saved_url`). The comparison is *value-based* so local j/k navigation (which doesn't touch `state.json`) is never overridden. Same `call_after_refresh` reason as the cursor-restore path: if sync fires right after a tree rebuild (blink cadence and rebuild cadence can line up), the leaves still have `line == -1` and a direct cursor move would silently snap to line 0 — which would then *stick*, since `_last_synced_cycle_url` is already updated and the next blink wouldn't retry. All programmatic cursor motion uses `move_cursor` rather than `select_node` because `select_node` posts a `Tree.NodeSelected` message — see "Enter routing" below.

**Stable Open Tabs order.** Chromium's `/json/list` returns tabs in MRU order on most builds, so every `cdp.activate` (from preview mode, Super+Alt+J/K cycling, or Enter) would reshuffle "Open Tabs" — the tab you just jumped to would pop to the top of the list, dragging its neighbors around. `_stable_sort_live` fixes this by maintaining a `self._live_order: list[str]` of tab ids in first-seen order: on each refresh it drops ids that no longer exist, appends newly-seen ids to the end, then returns the `cdp.Tab`s in that order. Only *position* is stabilized — titles and URLs still update live when the user navigates within a tab, since those are looked up per-id from the fresh `cdp.list_tabs()` response.

**Cursor survives rebuilds.** `_refresh_live` rebuilds the tree every 3 s, and `tree.clear()` resets the cursor to line 0 — without preservation, both local j/k navigation and the external-cycle cursor would be thrown away on every refresh. `_rebuild_tree` therefore captures the cursor's current row `url`/`kind` before clearing, then schedules `_restore_cursor` via `call_after_refresh` to re-move the cursor onto the matching leaf (live tabs checked via `_live_node`, saved tabs via `_saved_nodes`). The `call_after_refresh` indirection is required: right after `tree.clear()` + `add_leaf`, Textual hasn't laid out the new TreeNodes yet — each leaf's `line` attribute is still -1, so moving the cursor silently snaps it back to line 0. Deferring to the next refresh tick means layout has computed line numbers and the move actually lands on the right row. If the URL no longer resolves (tab closed, saved tab removed, filter excluded it), the cursor stays at 0 as a fallback. `_last_synced_cycle_url` is deliberately *not* cleared on rebuild — clearing it would force `_sync_cycle_cursor` to override the just-restored cursor on the next blink.

**Enter routing — why `move_cursor` over `select_node`.** Textual's `Tree` widget owns the `enter` key via its own built-in `Binding("enter", "select_cursor")`; because the tree is the focused widget, that binding wins and an App-level `Binding("enter", ...)` would never fire. `BmApp` therefore listens for `Tree.NodeSelected` at the App level (`on_tree_node_selected`) and translates it into `action_activate` for leaves whose `.data` is a `Row`. Group-header branches have `data=None` and fall through silently — Tree's own auto-expand hook handles their expand/collapse. The knock-on consequence: `Tree.select_node(leaf)` *also* posts `NodeSelected`, which our handler would now spuriously interpret as an Enter press. Every programmatic cursor move — `_restore_cursor`, `_select_saved_url`, and `action_collapse`'s "move to parent" fallback — therefore uses `move_cursor` (motion only, no message) instead. Helps behavior stay correct across: the 3 s live-refresh rebuild (would re-activate the cursor tab on every tick), the `Super+Alt+J/K` external-cycle sync (would double-activate), and pressing `h` on a leaf (would collapse/expand its parent group as a side effect).

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

# Edge-to-edge — the inherited 14px padding renders opaque while the
# terminal cells are transparent, which looks like an ugly frame at low
# opacity. Zero padding makes the TUI fill the window edge-to-edge.
window-padding-x = 0
window-padding-y = 0

# Drop the GTK titlebar — the black "bm" strip at the top breaks the
# edge-to-edge transparent look. Hyprland already manages the window.
window-decoration = false
```

**Colors follow the active omarchy theme.** `bm/theme.py` reads `~/.config/omarchy/current/theme/colors.toml` at startup and registers a Textual theme mapping `accent`, `foreground`, `background`, `surface`, `panel`, plus the standard ANSI palette into Textual's color system. The `dark=` flag on the registered Theme is computed from the background's Rec. 709 luminance (`_is_dark`), so light omarchy themes (catppuccin-latte, flexoki-light, rose-pine, white) get the correct Textual auto-shades instead of a hardcoded `dark=True`. Switch omarchy themes → restart `bm` → the TUI picks up the new palette.

For paths that need exact hex values (notably the help-screen key column), the TUI bypasses `self.current_theme` and reads the raw TOML dict via `bm_theme.load_colors()`. Rationale: Textual 8.x's new Content/markup system parses `[#RRGGBB]` as a variable reference rather than a raw color, and the Theme object can also normalize values passed to fields like `secondary`. Reading the dict and passing a `rich.style.Style(color=hex)` to `Text.append` is the one approach that reliably renders the literal per-theme hex. The osaka-jade exception uses `bm_theme.load_name()` which reads the theme name from `~/.config/omarchy/current/theme.name`.

**Transparency approach.** `tui.tcss` sets `background: transparent` on a universal `*` rule plus an explicit `App, Screen, Vertical, Container, Tree, Input` rule (Textual's built-in per-widget defaults beat a single `*` on specificity). Transparent widget backgrounds cause Textual to emit cells with the terminal's default background — which is exactly what ghostty's `background-opacity` applies to. The cursor row (`.tree--cursor`) and its secondary `.tree--highlight` also stay transparent — selection is signalled by recoloring the row's text to `$accent`, walker-style, rather than painting a solid block behind it. Deliberately `text-style: not bold` on the cursor (not just omitted): Textual's built-in `.tree--cursor` component class sets `text-style: bold` and CSS cascades per-property, so dropping the declaration leaves the default in place. Explicit `not bold` is required to stop the cursor from bolding, which otherwise shifts glyph widths and makes the list jitter as the cursor moves. Blur is deliberately **off** — we want to see the desktop, not a frosted pane.

**Trade-off accepted:** text inside the TUI stays fully opaque (it's terminal text, not an image), so on busy wallpapers the text may feel slightly thin at `0.75`. Adjust `background-opacity` up or down in `bm.conf` if the default isn't to taste.

## Browser choice

Plain **chromium** — ships with omarchy by default, so no migration installs it. Reliable `--remote-debugging-port` support, lightweight, no vendor account needed.

Vivaldi is **not** used here — its `--remote-debugging-port` support has historically been unreliable, and Vivaldi Sync already covers that browser's own tab/workspace sync story. The two browsers coexist: Vivaldi for everyday browsing with workspaces, Chromium (via `bm`) as the git-synced saved-tabs workspace.

Chromium launches with `--user-data-dir=~/.config/bm/profile` so it keeps a dedicated profile, disjoint from any other Chromium install.

## Python / Textual install

Install via **uv tool install**, pointing at the bundled package under `files/local/share/bm/`. Self-contained venv, fast install, no pollution of system Python. Falls back to `pipx install` if uv is missing.

## Migration plan

Lands as a **new migration group `019`** (name: `bm-tool`), separate from the ongoing `018-updates` group so it's a self-contained install/rollback unit. Each migration has a matching rollback.

**Register the group** in `migrate.sh` and `scripts/rollback/rollback.sh`:

```bash
declare -A GROUP_NAMES=(
  ...
  [018]="updates" [019]="bm-tool"
)
GROUP_ORDER=(000 001 002 003 004 005 006 007 008 009 010 011 012 013 014 015 016 017 018 019)
```

**Scripts** (sequence numbers continue from the last one in 018; the rename runs first so the new `bm` binary isn't shadowed by the old bash function). Filenames follow the komarchy convention of uniform 17-character basenames (`NNN-NNNNN-CCC-AAA`, where `CCC` is a 3-char category and `AAA` a 3-char action). Category `bms` = **b**ookmark-**m**anager **s**idebar; `bmd` = **b**ookmark-**m**arkdown (the renamed predecessor).

| Script | Purpose |
|---|---|
| `019-00108-bmd-ren.sh` | Rename the existing `bm()` bash function in `~/.bashrc` to `bmd()`, freeing `bm` as a command name. Idempotent: no-op if already renamed. |
| `019-00109-bms-uvi.sh` | Install `uv` via pacman (if missing) |
| `019-00110-bms-app.sh` | `uv tool install` the Textual `bm` package |
| `019-00111-bms-bin.sh` | Copy the `bm` launcher to `~/.local/bin/bm`, the dedicated Ghostty config to `~/.config/ghostty/bm.conf`, and seed `~/.config/omarchy/bm/saved-tabs.json` (preserving any existing one) |
| `019-00112-bms-hyp.sh` | Append Super+Alt+hjkl leader block and marker-comment windowrules block to Hyprland config |

**Rollback behavior** (important for the `rollback → migrate` test cycle):

- `019-00110` rollback runs `uv cache clean bm` after uninstalling so subsequent installs don't hit a stale wheel cache
- `019-00111` rollback wipes `~/.config/omarchy/bm/` (saved tabs), `~/.config/bm/` (UI state + dedicated chromium profile), and `~/.cache/bm/` (favicon cache) — truly clean state, no user data preserved

**Interaction with `018-00073-bkm-als.sh`**: the existing migration that installs `bm()` is not edited. Fresh installs run it, get `bm()` in `.bashrc`, then `019-00108-bmd-ren.sh` immediately converts it to `bmd()`. Already-migrated users just run the 019 rename. The rollback of `019-00108-bmd-ren.sh` restores `bm()` → consistent with the original 018 migration.

Chromium is not installed by a migration — omarchy ships with it, so `bm` relies on that. If you wipe omarchy's defaults, reinstall `chromium` manually before running these.

## Phased rollout

- **Phase 1** — Textual TUI with open-or-switch, live tabs list, saved tabs with groups, favicons via Kitty graphics, Hyprland tiling, `bm` CLI subcommands (`open`, `save`, `list`, `rm`) for scripted use.
- **Phase 2** — polish: drag-to-reorder saved tabs, bulk import/export, search-across-tab-content via CDP `Runtime.evaluate`, per-group colors.
- **Phase 3** *(optional)* — Neovim plugin that reads the same `saved-tabs.json` and hits the same CDP endpoints for in-editor tab jumps (via Telescope / fzf-lua picker). Supplementary to `bm`, not a replacement.

## Resolved decisions

All four originally-open decisions landed as follows:

- **Sidebar width** — 300 px (tunable via `BM_SIDEBAR_WIDTH` env var)
- **Group model** — flat `group` string per tab
- **Enter behavior** — activates the tab, raises chromium, and exits the TUI (drops the user back at their shell)
- **Auto-launch chromium** — yes. If CDP isn't reachable on `:9222`, `bm` spawns a dedicated chromium profile (`~/.config/bm/profile`) before running the TUI

## Trade-offs vs. Zen / Vivaldi Sync

| What this wins | What this loses |
|---|---|
| Saved tabs are plain JSON in git — diffable, scriptable, reviewable | No live tab sync across machines — only saved tabs travel |
| No vendor account, no cloud dependency | No mobile companion |
| Fully keyboard-driven, vim-native | You maintain the code |
| Reuses your existing terminal, font, theme, Hyprland setup | Less polished than Arc/Zen out of the box |
| One codebase drives CLI, TUI, and optional nvim plugin | |
