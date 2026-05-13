import { addTab, loadStore, loadTheme } from "./storage.js";
import type { SavedTab, Store } from "./types.js";

const $select = document.getElementById("workspace-select") as HTMLSelectElement;
const $tree = document.getElementById("tab-tree") as HTMLElement;
const $save = document.getElementById("save-current") as HTMLButtonElement;

let store: Store | null = null;
let currentWorkspaceId: string | null = null;

// Vim-style cursor: index into the flat list of `.tab-row` elements in
// the current render. Recomputed after every render() because the rows
// themselves are rebuilt from scratch each time.
let cursorIndex = 0;
let navigableRows: HTMLElement[] = [];

async function refresh(): Promise<void> {
  try {
    store = await loadStore();
  } catch (err) {
    renderError(err);
    return;
  }
  // Theme lookup is best-effort: if omarchy isn't installed or the
  // file is missing, the helper returns {} and we keep the baked-in
  // CSS defaults.
  try {
    const theme = await loadTheme();
    applyTheme(theme);
  } catch {
    /* swallow — theme load is non-fatal */
  }
  if (!currentWorkspaceId) {
    const persisted = await chrome.storage.local.get("currentWorkspaceId");
    currentWorkspaceId =
      (persisted.currentWorkspaceId as string | undefined) ??
      store.workspaces[0]?.id ??
      null;
  }
  render();
  // Re-grab focus now that rows exist. On cold mount this is the call
  // that lands focus on the cursor row, which is the one chromium
  // actually routes keystrokes to after a background-triggered open.
  grabFocus();
}

function applyTheme(theme: Record<string, string | undefined>): void {
  // CSS custom properties on :root cascade everywhere; rules in style.css
  // reference them with `var(--bm-bg, <fallback>)` so missing keys still
  // get a sensible value.
  const root = document.documentElement.style;
  if (theme.background) {
    // For dark themes, render 30% darker than the omarchy bg so the bm
    // panel reads as "below" the chrome. For light themes, that would
    // muddy the surface — use the theme bg as-is instead.
    const bg = isLightColor(theme.background)
      ? theme.background
      : `color-mix(in srgb, ${theme.background} 70%, black 30%)`;
    root.setProperty("--bm-bg", bg);
  }
  if (theme.foreground) root.setProperty("--bm-fg", theme.foreground);
  if (theme.accent) root.setProperty("--bm-accent", theme.accent);
}

function isLightColor(hex: string): boolean {
  // Perceived luminance via Rec. 709 weights, normalised 0..1. Threshold
  // at 0.5 — well above any dark omarchy theme bg (~0.12) and well below
  // typical light themes (~0.9+).
  const h = hex.startsWith("#") ? hex.slice(1) : hex;
  if (h.length !== 6) return false;
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  if ([r, g, b].some(Number.isNaN)) return false;
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5;
}

function renderError(err: unknown): void {
  $tree.innerHTML = "";
  const msg = err instanceof Error ? err.message : String(err);
  const wrap = document.createElement("div");
  wrap.className = "error";
  const h = document.createElement("h2");
  h.textContent = "Can't reach the native helper";
  const p = document.createElement("p");
  p.textContent = msg;
  const hint = document.createElement("p");
  hint.className = "hint";
  hint.textContent =
    "Install the native messaging host: ./install.sh <EXTENSION_ID> from files/local/share/bm-ext/native-helper/";
  wrap.append(h, p, hint);
  $tree.append(wrap);
}

function render(): void {
  if (!store) return;

  $select.innerHTML = "";
  for (const ws of store.workspaces) {
    const opt = document.createElement("option");
    opt.value = ws.id;
    opt.textContent = ws.name;
    if (ws.id === currentWorkspaceId) opt.selected = true;
    $select.append(opt);
  }

  $tree.innerHTML = "";
  const tabs = store.tabs.filter((t) => t.workspace === currentWorkspaceId || t.workspace == null);
  if (tabs.length === 0) {
    const p = document.createElement("p");
    p.className = "placeholder";
    p.textContent = "No saved tabs in this workspace.";
    $tree.append(p);
    return;
  }

  const byGroup = new Map<string, SavedTab[]>();
  for (const tab of tabs) {
    const list = byGroup.get(tab.group) ?? [];
    list.push(tab);
    byGroup.set(tab.group, list);
  }

  for (const [group, items] of byGroup) {
    const section = document.createElement("section");
    section.className = "group";
    const h = document.createElement("h2");
    h.textContent = group;
    section.append(h);
    const ul = document.createElement("ul");
    for (const tab of items) {
      ul.append(renderRow(tab));
    }
    section.append(ul);
    $tree.append(section);
  }

  refreshNavigation();
}

function refreshNavigation(): void {
  navigableRows = Array.from($tree.querySelectorAll<HTMLElement>(".tab-row"));
  if (navigableRows.length === 0) {
    cursorIndex = 0;
    return;
  }
  // Clamp cursor in case the row count shrank between renders.
  cursorIndex = Math.min(Math.max(cursorIndex, 0), navigableRows.length - 1);
  applyCursor();
}

function applyCursor(): void {
  navigableRows.forEach((row, i) => {
    row.classList.toggle("is-cursor", i === cursorIndex);
  });
  navigableRows[cursorIndex]?.scrollIntoView({ block: "nearest" });
}

function moveCursor(delta: number): void {
  if (navigableRows.length === 0) return;
  const next = cursorIndex + delta;
  if (next < 0 || next >= navigableRows.length) return;
  cursorIndex = next;
  applyCursor();
}

function renderRow(tab: SavedTab): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "tab-row";

  const link = document.createElement("button");
  link.className = "tab-activate";
  link.type = "button";
  link.textContent = tab.title || tab.url;
  link.title = tab.url;
  link.addEventListener("click", () => void activateOrOpen(tab.url));

  li.append(link);
  return li;
}

async function activateOrOpen(url: string): Promise<void> {
  const existing = await chrome.tabs.query({ url });
  if (existing.length > 0 && existing[0].id != null) {
    await chrome.tabs.update(existing[0].id, { active: true });
    if (existing[0].windowId != null) {
      await chrome.windows.update(existing[0].windowId, { focused: true });
    }
    return;
  }
  await chrome.tabs.create({ url, active: true });
}

$select.addEventListener("change", async () => {
  currentWorkspaceId = $select.value;
  await chrome.storage.local.set({ currentWorkspaceId });
  render();
});

$save.addEventListener("click", async () => {
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!active?.url) return;
  const workspace = currentWorkspaceId ?? undefined;
  await addTab({
    id: crypto.randomUUID().replace(/-/g, ""),
    title: active.title ?? active.url,
    url: active.url,
    group: "Unsorted",
    added: new Date().toISOString().slice(0, 10),
    workspace,
  });
  await refresh();
});

// Pull keyboard focus into the side panel when the background service
// worker tells us to (e.g., Alt+Shift+B fired while a chromium tab was
// focused). Focusing body alone leaves chromium routing keystrokes to
// the previously-focused tab; focusing a *real interactive element*
// (the cursor row's button) is more authoritative and pulls the frame
// focus reliably. Body fallback keeps the cold-mount path working
// before any rows exist.
function grabFocus(): void {
  window.focus();
  const cursorEl = navigableRows[cursorIndex];
  const target =
    cursorEl?.querySelector<HTMLElement>(".tab-activate") ?? document.body;
  target.focus({ preventScroll: true });
}

chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.type === "focus-self") {
    grabFocus();
  }
});

// Focus on cold mount so j/k works the moment the panel paints,
// without the user needing to click into it first.
grabFocus();

// Vim-style navigation. Bound on document so the panel doesn't need an
// element to hold focus for keys to land — typing into the workspace
// select still gets the native ArrowUp/Down behavior because we bail on
// SELECT focus.
document.addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.altKey || e.metaKey || e.shiftKey) return;
  const tag = (document.activeElement?.tagName ?? "").toUpperCase();
  if (tag === "SELECT" || tag === "INPUT" || tag === "TEXTAREA") return;

  if (e.key === "j") {
    moveCursor(1);
    e.preventDefault();
  } else if (e.key === "k") {
    moveCursor(-1);
    e.preventDefault();
  }
});

void refresh();
