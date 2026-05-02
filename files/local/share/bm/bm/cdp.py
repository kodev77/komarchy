from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlsplit, parse_qsl
import json
import httpx

from websockets.sync.client import connect as ws_connect
from websockets.exceptions import WebSocketException

from .paths import CDP_BASE


@dataclass
class Tab:
    id: str
    title: str
    url: str
    favicon_url: Optional[str]
    kind: str
    # Per-tab DevTools WebSocket endpoint from /json/list. Required by
    # `visible_tab` to probe document.visibilityState — /json/list's
    # array order doesn't reliably identify the focused tab (chromium
    # leaves background-opened tabs at MRU position 0 indefinitely),
    # so the visibility API is the source of truth.
    ws_url: Optional[str]

    @classmethod
    def from_json(cls, data: dict) -> "Tab":
        return cls(
            id=data.get("id", ""),
            title=data.get("title", "") or data.get("url", ""),
            url=data.get("url", ""),
            favicon_url=data.get("faviconUrl") or None,
            kind=data.get("type", "page"),
            ws_url=data.get("webSocketDebuggerUrl") or None,
        )


class CDPError(Exception):
    pass


def _client(timeout: float = 2.0) -> httpx.Client:
    return httpx.Client(base_url=CDP_BASE, timeout=timeout)


def is_up() -> bool:
    try:
        with _client(timeout=0.5) as c:
            c.get("/json/version")
        return True
    except httpx.HTTPError:
        return False


def list_tabs() -> list[Tab]:
    with _client() as c:
        r = c.get("/json/list")
        r.raise_for_status()
        return [Tab.from_json(t) for t in r.json() if t.get("type") == "page"]


def activate(tab_id: str) -> None:
    with _client() as c:
        r = c.put(f"/json/activate/{tab_id}")
        r.raise_for_status()


def new_tab(url: str) -> Tab:
    # CDP expects the target URL as the raw query string, not a key=value pair.
    from urllib.parse import quote
    with _client() as c:
        r = c.put(f"/json/new?{quote(url, safe=':/?&=#%')}")
        r.raise_for_status()
        return Tab.from_json(r.json())


def close_tab(tab_id: str) -> None:
    with _client() as c:
        r = c.put(f"/json/close/{tab_id}")
        r.raise_for_status()


def find_by_url(url: str, tabs: Optional[list[Tab]] = None) -> Optional[Tab]:
    tabs = tabs if tabs is not None else list_tabs()
    for t in tabs:
        if _urls_match(t.url, url):
            return t
    return None


# Query keys that identify the "what" of a tab — when the target URL
# specifies one of these, the live tab must agree on its value or the
# two are treated as different tabs. Lets `q=ibm+5150` and `q=javascript`
# stay distinct on Google instead of both collapsing onto whichever
# Google tab happens to be open. Other query params (session ids,
# tracking, sca_esv, etc.) are ignored so the existing Gmail-style
# loose match still works.
_SEARCH_QUERY_KEYS = {"q", "query", "search"}


_VISIBILITY_TIMEOUT = 0.3


def _is_visible(ws_url: str) -> Optional[bool]:
    """Open a one-shot WS to a tab's debugger endpoint, ask
    document.visibilityState, return True iff 'visible'. None on any
    failure (timeout, WS error, JSON parse, missing field) so callers
    can fall through to the next candidate without distinguishing
    "definitely hidden" from "couldn't tell".

    Per-call connect — chromium-local, ~5ms round-trip. A pooled
    long-lived WS would amortize the handshake but adds reconnect
    bookkeeping for so few probes per tick.
    """
    try:
        with ws_connect(
            ws_url,
            open_timeout=_VISIBILITY_TIMEOUT,
            close_timeout=_VISIBILITY_TIMEOUT,
        ) as ws:
            ws.send(json.dumps({
                "id": 1,
                "method": "Runtime.evaluate",
                "params": {"expression": "document.visibilityState"},
            }))
            raw = ws.recv(timeout=_VISIBILITY_TIMEOUT)
        msg = json.loads(raw)
        return msg.get("result", {}).get("result", {}).get("value") == "visible"
    except (WebSocketException, OSError, json.JSONDecodeError, TimeoutError):
        return None


def visible_tab(
    tabs: list[Tab], prefer_id: str = ""
) -> Optional[Tab]:
    """Return the tab chromium is currently showing as the front tab in
    its window, by querying the W3C Page Visibility API on each
    candidate. /json/list's array order doesn't track focus reliably
    — a background-opened tab (right-click → Open in new tab,
    middle-click) sits at MRU position 0 indefinitely until the user
    manually clicks it, so picking position 0 stole the active
    highlight in bm whenever the user opened a link in the
    background. visibilityState is the spec-correct signal.

    `prefer_id` (typically the prior known-visible tab id) is probed
    first so the steady-state cost is one WS round-trip — the user
    isn't usually switching tabs every refresh tick. On a miss, falls
    through to scanning `tabs` in order. Returns None when no tab
    reports visible (chromium minimized/occluded, or all probes
    failed) so the caller can keep the prior active highlight in
    place rather than blanking it.
    """
    by_id = {t.id: t for t in tabs}
    if prefer_id and prefer_id in by_id:
        t = by_id[prefer_id]
        if t.ws_url and _is_visible(t.ws_url):
            return t
    for t in tabs:
        if t.id == prefer_id:
            continue
        if not t.ws_url:
            continue
        if _is_visible(t.ws_url):
            return t
    return None


def _urls_match(a: str, b: str) -> bool:
    """Two URLs refer to the same logical tab when host + path match
    (case-insensitive host, trailing slash + fragment ignored) AND
    every search-query key present in `b` (the target URL we're trying
    to activate) carries the same value in `a` (the candidate live
    tab). Other query params are intentionally ignored: chromium
    often rewrites tracking/session ids on the response, and SPA
    routes like Gmail's `?tab=rm&ogbl` shouldn't force a duplicate
    tab when the user saved the bare domain."""
    pa = urlsplit(a.strip())
    pb = urlsplit(b.strip())
    if pa.netloc.lower() != pb.netloc.lower():
        return False
    if pa.path.rstrip("/") != pb.path.rstrip("/"):
        return False
    qa = dict(parse_qsl(pa.query, keep_blank_values=True))
    qb = dict(parse_qsl(pb.query, keep_blank_values=True))
    for key in _SEARCH_QUERY_KEYS:
        if key in qb and qa.get(key) != qb.get(key):
            return False
    return True
