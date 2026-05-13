# Bookmark Manager — Tauri Native App (Plan)

Replaces the bm TUI *and* the chromium side panel extension with a Rust-backed Tauri app: a real Wayland window owned by us, rendering the existing HTML/CSS/TypeScript UI from the extension work, with Rust handling file I/O and Chromium control via CDP.

This doc is the **target architecture**. The TUI (group 019) and the chromium extension scaffold (group 027) keep shipping until the Tauri app reaches feature parity; existing migrations are not removed until the cutover.

## Why this exists

Two prior approaches each hit a fundamental constraint:

| Approach | Constraint hit |
|---|---|
| **TUI in ghostty/alacritty** | Tied to whichever terminal Omarchy ships as default. Omarchy 3.7 drop of ghostty broke `bm focus`; future shifts will require similar patches. |
| **Chromium side-panel extension** | Chromium intentionally blocks extensions from moving frame focus. `Super+Alt+H` could open the panel but couldn't *refocus* it once open — no API can solve this from inside the extension contract. |

A native Wayland window owned by our binary has neither constraint:

- It's not a terminal, so terminal-package churn doesn't affect us.
- It's a real top-level window with its own `app_id`, so Hyprland can focus it freely via `hyprctl dispatch focuswindow class:com.ko.bm` — the *same* mechanism the python TUI used successfully for years before the ghostty drop.

The Tauri framework specifically is chosen because **the UI work from the chromium-extension exploration ports directly** (HTML/CSS/TypeScript), turning what would otherwise be weeks of UI rebuilding into a port of just the Rust backend.

## Architecture

```
┌────────────── Hyprland workspace ────────────────────────────────────┐
│                                                                      │
│  ┌─────────────────────────────┐   ┌──────────────────────────────┐  │
│  │  Tauri app (the bm binary)  │   │  Chromium (bm profile)       │  │
│  │  app_id: com.ko.bm          │   │  --remote-debugging-port=9222│  │
│  │                             │   │                              │  │
│  │  ┌───────────────────────┐  │   │                              │  │
│  │  │ webview (WebKitGTK)   │  │   │                              │  │
│  │  │  - sidepanel.html     │  │◀──┤  CDP HTTP/WS on localhost:9222│  │
│  │  │  - sidepanel.ts (UI)  │  │   │                              │  │
│  │  │  - style.css          │  │   │                              │  │
│  │  │  - Berkeley Mono ttf  │  │   │                              │  │
│  │  └─────────┬─────────────┘  │   └──────────────────────────────┘  │
│  │            │ invoke()        │                                     │
│  │            ▼                 │                                     │
│  │  ┌───────────────────────┐  │   ┌──────────────────────────────┐  │
│  │  │ Rust backend          │──┼──▶│ saved-tabs.json (komarchy)   │  │
│  │  │  - file I/O           │  │   │ files/config/omarchy/bm/     │  │
│  │  │  - CDP client         │  │   └──────────────────────────────┘  │
│  │  │  - theme reader       │  │                                     │
│  │  │  - window mgmt        │  │   ┌──────────────────────────────┐  │
│  │  └───────────────────────┘  │──▶│ omarchy theme colors.toml    │  │
│  └─────────────────────────────┘   └──────────────────────────────┘  │
│           ▲                                                          │
│           │ Super+Alt+H                                              │
│           │ hyprctl dispatch focuswindow class:com.ko.bm             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Three pieces:

1. **Tauri window** — real Wayland surface, `app_id = com.ko.bm`. Hyprland windowrule already targets this class (existed in the TUI era). Frameless, transparent, blurred — see "Glass background" section below.
2. **Webview frontend** — the same `sidepanel.html`/`sidepanel.ts`/`style.css` we built for the chromium extension, with two adjustments: replace `chrome.runtime.sendNativeMessage` calls with `invoke()` to the Rust backend, and replace `chrome.tabs.*` calls with `invoke()` for CDP-backed tab operations.
3. **Rust backend** — reads/writes `saved-tabs.json` directly (no native messaging dance), talks to chromium via CDP for tab control, watches omarchy's `colors.toml` for theme changes.

## Tech stack

| Component | Choice | Rationale |
|---|---|---|
| Framework | **Tauri 2.x** | Active maintenance, transparent windows, single-binary output |
| Backend language | **Rust (1.75+)** | Tauri's native language, mature ecosystem |
| Frontend | **TypeScript + Vite** | Same setup as the extension; reuses build chain |
| CDP client | **chromiumoxide** | Well-maintained async Rust CDP crate |
| File watching | **notify** | For live theme/saved-tabs reloading |
| Window class | **com.ko.bm** | Matches existing Hyprland windowrule |
| Webview | WebKitGTK (Linux default) | Tauri-managed; supports compositor alpha |
| Font bundling | Tauri resources | Bundle `BerkeleyMono-Regular.ttf` etc. into binary |

Out-of-scope language choices: egui, iced, slint, gtk-rs. All viable for a pure-Rust GUI, but they'd require rebuilding the UI from scratch instead of porting the existing TS/CSS. Memory savings (60-100 MB) don't justify the rewrite cost for a personal tool used in a 16 GB+ environment.

## Reuse from the extension exploration

The chromium-extension work is **not** sunk cost — it becomes the frontend of this app. Files that port roughly 1:1:

| Source | Destination | Changes |
|---|---|---|
| `bm-ext/extension/src/sidepanel.html` | `bm-tauri/frontend/src/index.html` | Title tag, script src |
| `bm-ext/extension/src/sidepanel.ts` | `bm-tauri/frontend/src/main.ts` | `sendNativeMessage` → `invoke("load_store")` etc.; `chrome.tabs.*` → `invoke("activate_tab", ...)`; `chrome.runtime.onMessage` → Tauri event listener |
| `bm-ext/extension/src/storage.ts` | `bm-tauri/frontend/src/storage.ts` | Wraps `invoke()` instead of `sendNativeMessage` |
| `bm-ext/extension/src/types.ts` | `bm-tauri/frontend/src/types.ts` | Unchanged (matches `saved-tabs.json` schema) |
| `bm-ext/extension/src/style.css` | `bm-tauri/frontend/src/style.css` | Add alpha to `body { background }` for blur; everything else unchanged |
| Berkeley Mono `.ttf` bundle | `bm-tauri/frontend/fonts/` | Same `@font-face` declarations |
| j/k navigation, cursor highlighting, workspace selector | identical | All UI behavior already implemented |

Files that get *replaced* by Rust equivalents:

| Old (extension/helper) | New (Tauri Rust backend) |
|---|---|
| `bm-ext/native-helper/bm-store.py` (load/add/remove via stdio JSON) | Rust `#[tauri::command] fn load_store()` etc. — direct file I/O, no IPC overhead |
| `bind-shortcuts.py`, `unbind-shortcuts.py` | N/A — no chromium-extension shortcuts anymore. Single Hyprland keybind. |
| `bm-ext-focus` script (CDP detect + wtype injection) | N/A — Hyprland `focuswindow class:com.ko.bm` is the entire focus story. One line. |
| `manifest.json`, `install.sh` (NM host) | N/A |

## Glass background

The misconception fought in the TUI era was that "Wayland controls window blur." It doesn't — Hyprland (the compositor) does, and it's per-window-rule, not global.

Setup:

1. **Tauri window config** (`tauri.conf.json`):
   ```json
   "windows": [{
     "transparent": true,
     "decorations": false,
     "label": "bm",
     "title": "bm"
   }]
   ```
   `transparent: true` gives the window surface a true alpha channel.

2. **CSS** (`style.css`):
   ```css
   body {
     background: color-mix(in srgb, var(--bm-bg) 75%, transparent);
   }
   ```
   The 75% opacity sets how much of the wallpaper-behind shows through.

3. **Hyprland windowrule** (already exists for `com.ko.bm` from TUI era; extend as needed in `looknfeel.conf`):
   ```conf
   windowrule = blur,        class:com.ko.bm
   windowrule = noborder,    class:com.ko.bm
   windowrule = noshadow,    class:com.ko.bm
   ```
   The `blur` rule is what makes the wallpaper-behind get the frosted-glass treatment. Without it, transparent backgrounds show the raw wallpaper.

End result: Berkeley Mono text on real frosted glass. Unlike ghostty's `background-opacity = 0.75` (which sampled the wallpaper itself and didn't get true compositor blur), this is the real thing.

## File layout in komarchy

```
files/local/share/bm-tauri/
├── frontend/                    # webview content
│   ├── index.html
│   ├── package.json
│   ├── tsconfig.json
│   ├── vite.config.ts
│   ├── src/
│   │   ├── main.ts              # ported from extension sidepanel.ts
│   │   ├── storage.ts           # invoke() wrappers
│   │   ├── types.ts             # saved-tabs schema
│   │   └── style.css            # ported, with alpha bg
│   └── fonts/                   # Berkeley Mono bundle (copied at build time)
├── src-tauri/                   # Rust backend
│   ├── Cargo.toml
│   ├── tauri.conf.json
│   ├── build.rs
│   └── src/
│       ├── main.rs              # Tauri app builder, window setup
│       ├── store.rs             # saved-tabs.json read/write
│       ├── cdp.rs               # chromiumoxide tab control
│       ├── theme.rs             # omarchy colors.toml parser
│       └── commands.rs          # #[tauri::command] surface
└── README.md
```

## MVP scope (v0)

Ship when these work end-to-end on `cargo tauri build`:

1. Binary launches a frameless transparent Wayland window with Hyprland app_id `com.ko.bm`.
2. Window renders workspaces + groups + saved tabs from `saved-tabs.json`.
3. Click a row → CDP-activates the matching open tab in bm-profile chromium, or opens a new tab if not currently open.
4. j/k navigation with cursor highlighting (already implemented in TS).
5. Workspace selector switches the visible workspace; selection persists across launches (Rust-side state file).
6. "+" button or `S` keybind → save the currently-active chromium tab into the current workspace's `Unsorted` group.
7. Theme follows omarchy: read `~/.config/omarchy/current/theme/colors.toml` at startup, recolor via CSS custom properties on `:root`.

That's it. Everything else is v1+.

## Deferred (v1+)

- `next`/`prev` cycling shortcuts.
- Workspace `create`/`rename`/`rm` from inside the app.
- Group reorder, tab edit (title/URL).
- Search/filter UI.
- Favicon rendering (chromium's own — via CDP or http fetch).
- Live-tabs view alongside saved ones.
- Hot-reload on `saved-tabs.json` changes (e.g., after `git pull`).
- Hot-reload on `colors.toml` changes (omarchy theme switch picked up immediately).

## Migration story (komarchy)

New migration group `028-bm-tauri`:

| Script | What it does | Rollback |
|---|---|---|
| `bex-rst.sh` | `rustup` install (or detect) | (no-op — rust toolchain stays) |
| `bex-bld.sh` | `cargo tauri build` produces release binary | `cargo clean` |
| `bex-bin.sh` | Install binary to `~/.local/bin/bm-tauri` | Remove binary |
| `bex-hyp.sh` | Add Hyprland windowrules (blur, noborder, noshadow) for `class:com.ko.bm`. Repoint `SUPER+ALT+H` to launch `bm-tauri` (or focus it if running) | Revert |
| `bex-cdp.sh` | Already done by group 027 (`--remote-debugging-port=9222`) | Skip if already present |

The chromium extension migration (`027-bm-chromium`) and the python TUI install (`019-bm-tool`) stay shipped until the Tauri app reaches feature parity, then get retired in their own migrations.

## Open questions

- **Window persistence**: should bm-tauri stay running between Super+Alt+H presses (a long-lived background process Hyprland focuses), or spawn-and-die (each press launches a new process)? Long-lived gives instant focus + theme-poll efficiency; spawn-and-die is simpler and matches how the TUI worked. Probably long-lived: cold-start of a Tauri app on Wayland can be 200-400ms, noticeable in the keybind flow.
- **CDP dependency**: bm-tauri talks to chromium via CDP. Chromium must be running with `--remote-debugging-port=9222` (done by group 027). If chromium isn't running, what should clicking a saved tab do? Options: launch chromium first, or just open the URL via `xdg-open` and lose the "switch to existing tab" feature.
- **Single-instance**: should `bm-tauri` enforce one window per user? Tauri has a single-instance plugin. Recommended yes.
- **Update workflow**: when we change the Rust code, the binary needs to be rebuilt. Komarchy migration `bex-bld.sh` handles fresh installs, but day-to-day rebuilds are manual `cargo tauri build`. Worth a `bm-tauri-rebuild` helper script.

## Memory vs. pure-Rust GUI

Tauri's memory overhead is ~80-100 MB heavier than a pure-Rust GUI (egui/iced/slint) on Linux due to the WebKitGTK runtime. Practical numbers:

| Stack | RSS at idle |
|---|---|
| egui | 10-25 MB |
| iced | 30-60 MB |
| slint | 15-40 MB |
| gtk-rs | 60-100 MB |
| **Tauri (this plan)** | **80-150 MB** |

Why Tauri anyway: the chromium-extension exploration produced a working TS/CSS/HTML UI that ports 1:1 to Tauri's webview. Rebuilding it in egui or iced would mean weeks of GUI work for ~80 MB of memory savings on a tool used a few dozen times a day. On a 16 GB+ machine the trade isn't close. On constrained hardware (4 GB), egui would be the right pick — that's an explicit reconsider-point if hardware ever changes.

## Non-goals

- Cross-platform support (Windows/Mac). Tauri builds for them but we don't ship there.
- Mobile.
- Replacing chromium's native bookmark bar.
- Real-time multi-machine sync. Git pull/push remains the sync model.
- A "browser" — bm-tauri is a bookmark/tab manager that talks to chromium; it does not render pages itself.
