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
@click.option(
    "--workspace",
    default=None,
    help="Workspace name to save into (default: current).",
)
def cmd_save(group: str, workspace: str | None) -> None:
    """Save the currently focused chromium tab."""
    if not cdp.is_up():
        click.echo("chromium CDP not reachable on :9222", err=True)
        sys.exit(1)
    workspace_id: str | None = None
    if workspace:
        target = store.find_workspace_by_name(workspace)
        if target is None:
            click.echo(f"unknown workspace: {workspace}", err=True)
            sys.exit(1)
        workspace_id = target.id
    else:
        # Default: current workspace as recorded by the running TUI (or
        # last-viewed). store.add_saved further falls back to
        # workspaces[0] when nothing's set yet.
        current = store.get_current_workspace()
        if current:
            workspace_id = current
    saved = actions.save_focused(group=group, workspace=workspace_id)
    if saved is None:
        click.echo("no focused tab", err=True)
        sys.exit(1)
    click.echo(f"saved: {saved.title} [{saved.group}]")


@main.command("list")
@click.option(
    "--workspace",
    default=None,
    help="Workspace name to filter by (default: current).",
)
@click.option(
    "--all",
    "show_all",
    is_flag=True,
    default=False,
    help="Print every saved tab across every workspace.",
)
def cmd_list(workspace: str | None, show_all: bool) -> None:
    """Print saved tabs as JSON. By default, scopes to the current
    workspace (matches the in-TUI rendering); pass --all to dump every
    saved tab regardless of workspace."""
    tabs = store.load_saved()
    if show_all:
        pass  # print everything
    else:
        if workspace is not None:
            target = store.find_workspace_by_name(workspace)
            if target is None:
                click.echo(f"unknown workspace: {workspace}", err=True)
                sys.exit(1)
            target_id = target.id
        else:
            target_id = store.get_current_workspace()
            if not target_id:
                # No state yet (fresh install) — fall back to the
                # first workspace so we still scope sensibly instead
                # of dumping everything.
                workspaces = store.load_workspaces()
                target_id = workspaces[0].id if workspaces else ""
        # Essentials are global so they show up regardless of the
        # workspace filter — matches the in-TUI rendering.
        tabs = [
            t for t in tabs
            if t.group == store.ESSENTIALS_GROUP or t.workspace == target_id
        ]
    click.echo(json.dumps(
        {"tabs": [t.__dict__ for t in tabs]},
        indent=2,
    ))


@main.command("rm")
@click.argument("url")
def cmd_rm(url: str) -> None:
    """Remove every saved tab matching URL (across all groups and workspaces)."""
    removed = store.remove_saved_by_url(url)
    if removed:
        click.echo(f"removed {removed}: {url}")
    else:
        click.echo(f"not found: {url}", err=True)
        sys.exit(1)


@main.group("workspace")
def cmd_workspace() -> None:
    """Manage workspaces (named saved-tab containers)."""


@cmd_workspace.command("list")
def cmd_workspace_list() -> None:
    """Print workspaces (id, name, current marker) as JSON."""
    workspaces = store.load_workspaces()
    current = store.get_current_workspace()
    payload = {
        "workspaces": [
            {"id": w.id, "name": w.name, "current": w.id == current}
            for w in workspaces
        ]
    }
    click.echo(json.dumps(payload, indent=2))


@cmd_workspace.command("create")
@click.argument("name")
def cmd_workspace_create(name: str) -> None:
    """Append a new workspace (empty groups, empty open-tab list)."""
    if not name.strip():
        click.echo("name cannot be empty", err=True)
        sys.exit(1)
    new = store.add_workspace(name)
    click.echo(f"created: {new.name} ({new.id})")


@cmd_workspace.command("rm")
@click.argument("name")
def cmd_workspace_rm(name: str) -> None:
    """Destroy workspace + its saved tabs + its open-tab state.
    Refuses on the only remaining workspace.
    """
    target = store.find_workspace_by_name(name)
    if target is None:
        click.echo(f"unknown workspace: {name}", err=True)
        sys.exit(1)
    if not store.remove_workspace(target.id):
        # The only failure store.remove_workspace returns False for is
        # "would leave zero workspaces". Translate to a clear error.
        click.echo("cannot remove the only workspace", err=True)
        sys.exit(1)
    # Drop the per-workspace open-tab list from state.json so the next
    # bm boot doesn't carry stale URL associations.
    state = store.load_state()
    by_ws = state.get("openTabUrlsByWorkspace") or {}
    if target.id in by_ws:
        del by_ws[target.id]
        state["openTabUrlsByWorkspace"] = by_ws
        store.save_state(state)
    # If the user just removed the workspace they were last in, point
    # currentWorkspace at the new top of the array so the next bm
    # launch boots into a valid one.
    if store.get_current_workspace() == target.id:
        remaining = store.load_workspaces()
        if remaining:
            store.set_current_workspace(remaining[0].id)
    click.echo(f"removed: {name}")


@cmd_workspace.command("next")
def cmd_workspace_next() -> None:
    """Cycle to the next workspace in the array (wraps).

    Signals the running bm TUI to advance its current workspace
    in-process — same path as the in-bm `;` keybind, so the external
    cycle walks the same workspace list the user sees. Silent no-op
    when the bm TUI isn't running. Bound to hyprland's Super+Alt+;.
    """
    actions.send_workspace_cycle_signal()


@cmd_workspace.command("switch")
@click.argument("name")
def cmd_workspace_switch(name: str) -> None:
    """Switch to the named workspace. Updates state.currentWorkspace
    so the next bm launch boots into it. (A running bm TUI re-reads
    workspace state on its next refresh tick or operation.)
    """
    target = store.find_workspace_by_name(name)
    if target is None:
        click.echo(f"unknown workspace: {name}", err=True)
        sys.exit(1)
    store.set_current_workspace(target.id)
    click.echo(f"switched to: {name}")


@main.command("browser")
def cmd_browser() -> None:
    """Focus the bm-launched chromium window. Reads the chromium PID
    that launcher._spawn wrote and dispatches hyprland focus by pid:NNN.

    Bound to Super+Alt+L. Silent no-op if bm chromium isn't running
    (stale or missing PID file), so the binding is harmless when bm
    is closed.

    Why PID-based: chromium on Wayland ignores --class=, so class-based
    hyprctl matching can't distinguish the bm chromium from any other
    chromium window the user has running.
    """
    actions.raise_chromium()


@main.command("next")
def cmd_next() -> None:
    """Cycle forward through every row bm's TUI would render (saved
    tabs + unpaired open tabs), activating the matching chromium tab
    while keeping current window focus.

    Silent no-op if chromium isn't running or there are fewer than
    two cycle entries. Bound to hyprland's Super+Alt+J — the "flip
    through my tabs from anywhere" workflow that mirrors bm's
    internal j+Enter navigation.
    """
    actions.send_cycle_signal(+1)


@main.command("prev")
def cmd_prev() -> None:
    """Cycle backward through every row bm's TUI would render,
    activating the matching chromium tab while keeping current window
    focus.

    Paired with `bm next` — bound to hyprland's Super+Alt+K.
    """
    actions.send_cycle_signal(-1)


if __name__ == "__main__":
    main()
