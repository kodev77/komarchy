# Tmux Keybindings (Omarchy)

Reference for the tmux config at `~/.config/tmux/tmux.conf`.

## Prefix Key

The prefix is **Ctrl+Space** (with **Ctrl+b** as a fallback). Bindings marked with "Prefix +" require pressing the prefix first.

## Panes

| Keybind | Action |
|---|---|
| Prefix + `h` | Split pane horizontally (top/bottom) |
| Prefix + `v` | Split pane vertically (left/right) |
| Prefix + `x` | Kill current pane |
| `Ctrl+Alt+Arrow` | Navigate between panes |
| `Ctrl+Alt+Shift+Arrow` | Resize pane by 5 cells |

## Windows (tabs)

| Keybind | Action |
|---|---|
| Prefix + `c` | New window (in current path) |
| Prefix + `k` | Kill window |
| Prefix + `r` | Rename window |
| `Alt+1` to `Alt+9` | Jump to window 1-9 |
| `Alt+Left/Right` | Previous/next window |
| `Alt+Shift+Left/Right` | Swap window left/right |

## Sessions

| Keybind | Action |
|---|---|
| Prefix + `C` | New session |
| Prefix + `K` | Kill session |
| Prefix + `R` | Rename session |
| Prefix + `P` | Previous session |
| Prefix + `N` | Next session |
| `Alt+Up/Down` | Previous/next session |

## Copy Mode

Enter copy mode with **Prefix + `[`**. Exit with `q` or `Esc`.

### Selecting and copying

| Keybind | Action |
|---|---|
| `v` | Begin selection |
| `y` | Copy selection and exit |

### Navigation (vi-style)

| Key | Action |
|---|---|
| `h j k l` | Move cursor left/down/up/right |
| `k` / `j` | Up / down one line |
| `Ctrl+u` / `Ctrl+d` | Half page up / down |
| `Ctrl+b` / `Ctrl+f` | Full page up / down |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `w` / `b` | Next / previous word |
| `0` / `$` | Start / end of line |
| `/` | Search forward |
| `?` | Search backward |
| `n` / `N` | Next / previous search match |

## Other

| Keybind | Action |
|---|---|
| Prefix + `q` | Reload tmux config |

Mouse support is enabled, so you can click panes, drag borders to resize, and scroll (scrolling drops you into copy mode automatically).

## Shell Helper Functions

Omarchy ships these tmux helpers in your shell:

- **`tdl <ai> [<ai2>]`** — Create a dev layout: editor (left), AI (right), terminal (bottom). e.g. `tdl c` opens nvim + claude.
- **`tdlm <ai> [<ai2>]`** — Same as `tdl` but opens one window per subdirectory in the current directory.
- **`tsl <count> <command>`** — Swarm layout: tile `<count>` panes all running the same command.
