// Mirrors files/config/omarchy/bm/saved-tabs.json (version 2).
// Keep field names byte-identical to the python bm so the same file
// round-trips between the two tools during the cutover window.

export interface Workspace {
  id: string;
  name: string;
}

export interface SavedTab {
  id: string;
  title: string;
  url: string;
  group: string;
  added: string;
  // Empty/absent on global "Essentials" tabs; uuid otherwise.
  workspace?: string;
}

export interface Store {
  version: number;
  workspaces: Workspace[];
  tabs: SavedTab[];
}

// Mirrors the keys in omarchy's ~/.config/omarchy/current/theme/colors.toml.
// All fields optional so a missing/partial theme file doesn't break the UI.
export interface Theme {
  background?: string;
  foreground?: string;
  accent?: string;
  cursor?: string;
  selection_foreground?: string;
  selection_background?: string;
  // color0..color15 ANSI palette keys flow through too.
  [key: string]: string | undefined;
}

// Wire format spoken to the native messaging helper.
export type StoreRequest =
  | { op: "load" }
  | { op: "add_tab"; tab: SavedTab }
  | { op: "remove_tab"; id: string }
  | { op: "get_theme" };

export type StoreResponse =
  | { ok: true; data: Store }
  | { ok: true; data: Theme }
  | { ok: false; error: string };
