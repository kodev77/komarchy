# bm TUI — Alacritty Terminal Port (Plan)

Restore the bm TUI on Omarchy 3.7+ by porting it from ghostty to alacritty. Ghostty was dropped from the Omarchy 3.7 default install, breaking bm's `cmd_focus` (it spawns a ghostty window to host the Textual TUI). Alacritty is now the Omarchy-default terminal and is installed on all current machines via group 025.

This is the **immediate fix** to restore the existing bm workflow. The long-term direction is a Tauri native app — see `bm-tauri-PLAN.md` — but that's weeks of Rust work. This port is hours.

## Scope

Four code touchpoints, plus migration plumbing.

### 1. Edit `files/local/bin/bm` — four surgical changes

| Current | New |
|---|---|
| `GHOSTTY_CONFIG="$HOME/.config/ghostty/bm.conf"` | `ALACRITTY_CONFIG="$HOME/.config/alacritty/bm.toml"` |
| `if [[ "$comm" == "ghostty" ]]; then` (in `self_ghostty_address`) | `if [[ "$comm" == "alacritty" ]]; then` |
| `if ! command -v ghostty >/dev/null` (in `cmd_focus`) | `if ! command -v alacritty >/dev/null` |
| `setsid ghostty --config-file="$GHOSTTY_CONFIG" -e "$0" …` | `setsid alacritty --class com.ko.bm --config-file="$ALACRITTY_CONFIG" -e "$0" …` |

Function names (`find_bm_ghostty_pid`, `self_ghostty_address`) stay — they're internal-only, and renaming creates churn for no behavioral gain. The script's *behavior* is what changes; the API surface (subcommands, exit codes) is unchanged.

### 2. New `files/config/alacritty/bm.toml`

Equivalent of the ghostty `bm.conf` settings, translated to alacritty's TOML schema:

```toml
[window]
opacity = 0.75
padding = { x = 10, y = 0 }
decorations = "None"

[font]
# Approximates ghostty's `adjust-cell-height = 30%` — ~6px extra at 13pt.
offset = { x = 0, y = 6 }
```

Notes:
- The `class = com.ko.bm` ghostty had in config is set via the `--class` flag at spawn instead — alacritty doesn't accept it in the config file.
- Blur is controlled by Hyprland's windowrule on `class:com.ko.bm`, not by terminal config (this matches the ghostty era's setup — the windowrule already exists).
- The font family is *not* set here — alacritty's main config already sets Berkeley Mono globally (from group 025). Setting it in `bm.toml` would be redundant.

### 3. New migration group `028-bm-tool-alc`

Two scripts plus matching rollbacks.

| Seq | Script | Action | Rollback strategy |
|---|---|---|---|
| `028-00146-bma-cfg.sh` | Install `bm.toml` to `~/.config/alacritty/bm.toml` | Remove the file |
| `028-00147-bma-bin.sh` | Re-install `bm` to `~/.local/bin/bm` (overwrites the ghostty-coupled version installed by group 019) | See "Open questions" |

Sequence numbers: group 027 (shelved chromium extension) used `00139-00145`. Next available is **`00146`**.

### 4. Register group 028 in `migrate.sh` and `scripts/rollback/rollback.sh`

```bash
# In both files:
GROUP_NAMES=(
  ... [025]="updates-om37" [027]="bm-chromium" [028]="bm-tool-alc"
)
GROUP_ORDER=(... 024 025 028)   # 027 stays shelved
```

## Test plan

After running migration 028:

1. `~/.config/alacritty/bm.toml` exists and contains the listed settings.
2. `~/.local/bin/bm` references `alacritty`, not `ghostty` (`grep alacritty ~/.local/bin/bm` finds matches; `grep ghostty` finds none in the changed call sites).
3. Press **Super+Alt+H** (Hyprland binding from group 019 calls `bm focus`).
4. An alacritty window spawns with `app_id = com.ko.bm` (`hyprctl clients` shows it).
5. Hyprland's existing windowrules for `com.ko.bm` (no_shadow, blur off, etc.) apply automatically — the class match is the same as before.
6. The bm Textual TUI runs inside the alacritty window, ready for vim navigation (j/k, etc.).
7. Berkeley Mono renders correctly (alacritty's global font, no per-window override needed).

If any step fails: diagnose at that step. No additional code changes anticipated for MVP scope.

## Open questions

### Rollback strategy for the bm script re-install (script #2)

Three viable approaches, decide at implementation time:

| Option | Behavior | Trade-off |
|---|---|---|
| **A** | Backup `~/.local/bin/bm` to `~/.local/bin/bm.pre-028.bak` before overwriting; restore on rollback. | Full rollback symmetry. Leaves a backup file behind if rollback never runs (small). |
| **B** | No backup. Rollback removes `~/.local/bin/bm`; user re-runs migration 019 to get the original (ghostty-coupled, broken-on-om37) version back. | Simpler. Rollback restores a broken state, which is dubious UX. |
| **C** | Rollback is a deliberate no-op for script #2 — leave the alacritty version in place. The ghostty version doesn't work on om37 anyway, so "rolling back" to it has no practical value. | Pragmatic; sacrifices rollback symmetry for end-user sanity. |

Lean: **A** for symmetry, **C** for pragmatism. Pick at start of implementation.

## Out of scope (deliberately)

- **Terminal-agnostic abstraction** (e.g., `$BM_TERMINAL` env var detecting whichever terminal is installed). Future improvement; would be valuable but isn't blocking and adds complexity. Tauri makes it irrelevant.
- **Removing the ghostty `bm.conf` from existing machines.** It's a harmless leftover; cleanup not worth a separate rollback path.
- **Updating `019-00111-bms-bin.sh` to install the alacritty config on fresh machines.** Could do for tidiness but 028 already covers both fresh and existing machines on the next migrate run.
- **Any changes to the Textual TUI itself** (`files/local/share/bm/bm/*.py`). That layer is terminal-agnostic — it's the host process (the terminal emulator running the TUI) that needed to change, not the TUI code.

## What stays in place untouched

- `files/local/share/bm/bm/*.py` — the Textual TUI source code.
- `files/config/omarchy/bm/saved-tabs.json` — same data file, same schema.
- Hyprland windowrule on `class:com.ko.bm` — already exists from group 019.
- Chromium CDP integration in the TUI — independent of which terminal hosts the TUI.
- Migration 019 (the original bm tool install) — kept "done" status; this group is additive.

## Implementation sequence

When picked up in a fresh session:

1. Confirm rollback strategy choice (A/B/C above).
2. Make the four edits to `files/local/bin/bm`.
3. Write `files/config/alacritty/bm.toml`.
4. Write `028-00146-bma-cfg.sh` + rollback.
5. Write `028-00147-bma-bin.sh` + rollback (with the chosen rollback strategy).
6. Update `migrate.sh` + `scripts/rollback/rollback.sh` to register group 028.
7. Run `migrate.sh` → `<028-bm-tool-alc>`.
8. Walk through the test plan steps.

Estimated time: 1-2 hours including testing.
