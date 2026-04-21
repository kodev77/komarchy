import json
import sys

import click

from . import actions, cdp, store


@click.group(invoke_without_command=True)
@click.pass_context
def main(ctx: click.Context) -> None:
    """bm — bookmark manager for Chromium via CDP."""
    if ctx.invoked_subcommand is None:
        from .tui import run_tui
        run_tui()


@main.command("open")
@click.argument("url")
def cmd_open(url: str) -> None:
    """Activate URL if already open, else open a new tab."""
    if not cdp.is_up():
        click.echo("chromium CDP not reachable on :9222", err=True)
        sys.exit(1)
    actions.open_or_switch(url)


@main.command("save")
@click.option("--group", default="Unsorted", show_default=True)
def cmd_save(group: str) -> None:
    """Save the currently focused chromium tab."""
    if not cdp.is_up():
        click.echo("chromium CDP not reachable on :9222", err=True)
        sys.exit(1)
    saved = actions.save_focused(group=group)
    if saved is None:
        click.echo("no focused tab", err=True)
        sys.exit(1)
    click.echo(f"saved: {saved.title} [{saved.group}]")


@main.command("list")
def cmd_list() -> None:
    """Print saved tabs as JSON."""
    tabs = store.load_saved()
    click.echo(json.dumps(
        {"tabs": [t.__dict__ for t in tabs]},
        indent=2,
    ))


@main.command("rm")
@click.argument("url")
def cmd_rm(url: str) -> None:
    """Remove a saved tab by URL."""
    if store.remove_saved(url):
        click.echo(f"removed: {url}")
    else:
        click.echo(f"not found: {url}", err=True)
        sys.exit(1)


@main.command("next")
def cmd_next() -> None:
    """Cycle forward through saved tabs, activating the matching chromium
    tab while keeping current window focus.

    Silent no-op if chromium isn't running or there are fewer than two
    saved tabs. Bound to hyprland's Super+Alt+J — the "flip through my
    bookmarks from anywhere" workflow that pairs with the TUI preview.
    """
    actions.cycle_saved_tab(+1)


@main.command("prev")
def cmd_prev() -> None:
    """Cycle backward through saved tabs, activating the matching chromium
    tab while keeping current window focus.

    Paired with `bm next` — bound to hyprland's Super+Alt+K.
    """
    actions.cycle_saved_tab(-1)


if __name__ == "__main__":
    main()
