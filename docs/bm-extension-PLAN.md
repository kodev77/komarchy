# Bookmark Manager — Chrome Extension Migration (Plan)

Replaces the terminal-coupled `bm` TUI with a Chromium extension. The Textual TUI + ghostty sidebar + CDP client go away. Saved tabs continue to live in komarchy's git-tracked `saved-tabs.json`, read/written through a small native messaging helper.

This plan is the **target state**. The current `bm` (group 019) keeps shipping until the extension reaches feature parity on the MVP slice below; existing migrations are not removed until the cutover.

## Why this exists

`bm` couples bookmarks to a specific terminal (was ghostty, dropped in Omarchy 3.7 → would have to port to alacritty). The data and UX have no reason to depend on which terminal is the default. An extension owns the tabs and the UI in the same process where the data lives — no PID tracking, no Hyprland focus dispatch, no process-tree walks, no CDP probe.

## Architecture

```
┌─────────────────── Chromium ────────────────────┐    ┌──────────────────────────┐
│                                                 │    │  Native messaging host   │
│  ┌─────────────────────────┐                    │    │  files/local/share/      │
│  │  Side panel UI          │   chrome.tabs.*    │    │    bm-ext/native-helper/ │
│  │  - workspace selector   │◀──────────────────▶│    │                          │
│  │  - grouped saved tabs   │                    │    │  reads/writes            │
│  │  - save / open / rm     │   NativeMessaging  │◀──▶│  files/config/omarchy/   │
│  │  - chrome.commands kb   │◀──────────────────▶│    │    bm/saved-tabs.json    │
│  └─────────────────────────┘   stdin/stdout     │    │  (the same file today)   │
│                                                 │    └──────────────────────────┘
└─────────────────────────────────────────────────┘
                                                          git push/pull = sync
```

Three boundaries:

1. **Extension** (TypeScript, MV3) — UI + chromium tab control. Lives in chromium's process, no awareness of Hyprland or the filesystem.
2. **Native helper** (Python, ~100 lines) — only job is to translate JSON-RPC-ish messages over stdin/stdout into reads/writes against `saved-tabs.json`. Lifetime is per-message: chromium spawns it, it does one thing, it exits.
3. **Git-tracked JSON** — `saved-tabs.json` schema stays the same (`version`, `workspaces[]`, `tabs[]`). The native helper preserves the existing v1→v2 migration logic so any older file still loads.

## File layout in komarchy

```
files/local/share/bm-ext/
├── extension/              # the loadable extension
│   ├── manifest.json
│   ├── src/
│   │   ├── sidepanel.html
│   │   ├── sidepanel.ts        # main UI
│   │   ├── background.ts       # service worker; chrome.commands; native msg
│   │   ├── storage.ts          # NativeMessaging client
│   │   ├── types.ts            # Workspace, SavedTab shapes
│   │   └── style.css
│   ├── package.json
│   ├── tsconfig.json
│   └── vite.config.ts
├── native-helper/
│   ├── bm-store.py             # the host binary (uv shebang for portability)
│   ├── manifest.json.in        # template for chromium's NativeMessagingHost
│   └── install.sh              # places manifest in ~/.config/chromium/NativeMessagingHosts/
└── README.md
```

Existing python tool stays at `files/local/share/bm/` during transition.

## Data flow

Read path (side panel load):

```
sidepanel.ts  → chrome.runtime.sendNativeMessage("com.ko.bm_store", {op: "load"})
              → bm-store.py reads saved-tabs.json, prints JSON to stdout
              → extension renders tree
```

Write path (save current tab):

```
chrome.commands.onCommand("bm-save")
  → background.ts: query active tab, build SavedTab record
  → sendNativeMessage({op: "add_tab", tab: {...}})
  → bm-store.py reads file, mutates, atomic-rename writes back
  → extension reloads tree from disk
```

The helper is the only writer. The extension never holds an in-memory canonical copy that can drift — every mutation round-trips through disk. Slightly more I/O, dramatically simpler invariants.

## MVP scope (v0)

Ship when these work end-to-end on a fresh chromium install:

1. Side panel opens via `chrome.commands` shortcut (e.g. Ctrl+Alt+B).
2. Side panel renders workspaces + groups + saved tabs from `saved-tabs.json` via native helper.
3. Click a tab row → if URL is already open, activate that tab; else open in new tab. (`chrome.tabs.query` + `chrome.tabs.update` / `chrome.tabs.create`.)
4. "Save current tab" command → adds a row to the current workspace's default group, writes JSON, re-renders.
5. Per-row "remove" button → removes by id, writes JSON, re-renders.
6. Workspace selector in the side panel header → switch current workspace, persist selection in `chrome.storage.local` (extension-local UI state, not user data).
7. Native messaging host installed into `~/.config/chromium/NativeMessagingHosts/com.ko.bm_store.json`.

That's it. Everything else is v1+.

## Deferred (v1+)

- `next` / `prev` cycling shortcuts (and the two-press gate semantics).
- Workspace `create` / `rm` from inside the side panel.
- Group reordering, group rename, tab edit (title, URL).
- Favicon rendering (use chrome's own — much simpler than the kitty-graphics path the TUI took).
- Search / filter UI.
- "Essentials" cross-workspace tabs UX.
- Live-tabs rendering (showing currently-open chromium tabs alongside saved ones).
- Migration of `bm.pid` / `chromium.pid` workflows — these don't exist in the extension model; the corresponding shell commands (`bm focus`, `bm browser`, `bm next/prev`) go away when this ships.

## Keybinds

**In-browser** (via `chrome.commands`, configured by user in `chrome://extensions/shortcuts`):

| Default | Action |
|---|---|
| Ctrl+Alt+B | Toggle side panel |
| Ctrl+Alt+S | Save current tab |
| (deferred) | Cycle next saved tab |
| (deferred) | Cycle previous saved tab |

**Hyprland** — shrinks to one binding:

```conf
bindd = SUPER ALT, L, focus chromium, exec, hyprctl dispatch focuswindow class:Chromium
```

The five Super+Alt bindings that exist today (H/J/K/L/;) collapse to just `L`. The rest are inside chromium where they belong.

## Migration steps (komarchy)

When MVP is ready:

1. New migration group (likely **026-bm-extension** to keep `025-updates-om37` focused on terminal-styling).
2. Migration script: `npm install && npm run build` in `files/local/share/bm-ext/extension/`, then point chromium to the built `dist/` as an unpacked extension via policy or instruct user to "Load unpacked" once.
3. Migration script: render `native-helper/manifest.json.in` with the user's `$HOME` and install to `~/.config/chromium/NativeMessagingHosts/com.ko.bm_store.json`.
4. Migration script: update `~/.config/hypr/bindings.conf` — remove the `--- BEGIN ko komarchy bm-tool bindings ---` block, add the single `Super+Alt+L` rule.
5. Migration script: stop installing the python `bm` (mark group 019 superseded but leave migrations in place for rollback symmetry).
6. Add rollback scripts for everything in step 1–4 so the python bm can be restored if the extension proves unworkable.

## Open questions

- **Chromium extension distribution.** Web Store requires a developer account + signing. For a personal tool installed via komarchy, "Load unpacked" pointed at the built `dist/` is fine — but it shows a "Disable developer mode extensions" nag every chromium startup. Acceptable, or worth packaging as `.crx` and self-signing?
- **Native messaging host name.** Proposing `com.ko.bm_store` to match the existing `com.ko.bm` Hyprland windowrule scheme. Lock this in early because it has to match between the host manifest, extension manifest, and the `sendNativeMessage` calls.
- **Should the extension talk to chromium's bookmarks API at all?** Today's bm sits *next* to chromium bookmarks, not integrating with them. Same plan here (workspaces ≠ Chrome bookmark folders), but worth confirming.
- **Single chromium profile or dedicated profile?** Today bm spawns chromium with `--user-data-dir=~/.config/bm/profile`. The extension model doesn't require a dedicated profile, but using your main profile means the extension sees all your tabs (work + personal). Keep dedicated, or merge?

## Non-goals

- Cross-browser support (Firefox/Edge).
- Mobile.
- Real-time multi-machine sync. Git pull/push is the sync model, same as today.
- Replacing chromium's native bookmark bar / star-icon UX.
