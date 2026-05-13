# bm — Chromium extension

Replacement for the bm TUI. See `../../../docs/bm-extension-PLAN.md` for design.

## Build

```sh
npm install
npm run build
```

Output lands in `dist/` — that's the dir you point chromium at when loading unpacked.

## First-time load

1. Build the extension (above).
2. Open `chrome://extensions/`, enable **Developer mode**, click **Load unpacked**, select the `dist/` dir.
3. Copy the assigned extension ID from the card — you need it to install the native messaging host (see `../native-helper/install.sh`).
4. Install the native messaging host with that ID:
   ```sh
   ../native-helper/install.sh <EXTENSION_ID>
   ```
5. Reload the extension. Open the side panel via the toolbar action or `Alt+Shift+B`.

> **Note on `suggested_key` choice.** Chromium rejects `Ctrl+Alt+<letter>` for command shortcuts because it collides with the AltGr key on many keyboard layouts. The validator fails with `Invalid value for 'commands[N].default'`. Use `Alt+Shift+<letter>` or `Ctrl+Shift+<letter>` instead.

## Open questions

Captured here so future-you sees them when you reload the project:

- **Distribution.** v0 uses "Load unpacked" + the developer-mode nag at every chromium startup. If that gets old, switch to a self-signed `.crx` and a `chromium --load-extension=<path>` flag, or set up an enterprise policy file under `/etc/chromium/policies/managed/`.
- **NM host name.** Locked as `com.ko.bm_store`. Changing it means re-rendering `native-helper/manifest.json.in`, re-running `install.sh`, and updating `HOST` in `src/storage.ts`.
- **Bookmarks API.** Not used. The extension stays alongside chromium's bookmark bar.
- **Profile.** v0 assumes the existing `--user-data-dir=~/.config/bm/profile` dedicated profile. The extension itself doesn't care, but the migration script that installs it does.

## Layout

```
extension/
├── manifest.json              # MV3, side_panel + nativeMessaging perms
├── package.json
├── tsconfig.json
├── scripts/copy-static.mjs    # copies html/css/manifest into dist/
└── src/
    ├── background.ts          # service worker; chrome.commands; native msg send
    ├── sidepanel.html         # side panel shell
    ├── sidepanel.ts           # side panel UI (workspace selector, tab tree)
    ├── storage.ts             # NativeMessaging client (load/add/remove)
    ├── style.css
    └── types.ts               # mirrors saved-tabs.json v2 schema
```

## What works in v0

- Side panel opens via toolbar action or `Ctrl+Alt+B`.
- Renders workspaces + groups + saved tabs from `saved-tabs.json` (read via native helper).
- Click a tab row → activate that tab if open, else open it.
- "+" button or `Ctrl+Alt+S` → save current tab to current workspace's `Unsorted` group.
- "×" per row → remove saved tab.
- Workspace selector switches the visible workspace; selection persists in `chrome.storage.local`.

## Deferred (v1+)

- next/prev cycling via `chrome.commands`.
- Workspace create/rename/delete UI.
- Group reorder, tab edit.
- Search/filter.
- Favicons (use chrome's, not kitty-graphics).
- Live-tabs view alongside saved tabs.
