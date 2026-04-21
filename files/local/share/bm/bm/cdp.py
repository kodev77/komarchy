from dataclasses import dataclass
from typing import Optional
import httpx

from .paths import CDP_BASE


@dataclass
class Tab:
    id: str
    title: str
    url: str
    favicon_url: Optional[str]
    kind: str

    @classmethod
    def from_json(cls, data: dict) -> "Tab":
        return cls(
            id=data.get("id", ""),
            title=data.get("title", "") or data.get("url", ""),
            url=data.get("url", ""),
            favicon_url=data.get("faviconUrl") or None,
            kind=data.get("type", "page"),
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


def _urls_match(a: str, b: str) -> bool:
    return _norm(a) == _norm(b)


def _norm(u: str) -> str:
    # Match on host + path only. Query and fragment vary across reloads
    # (e.g. Gmail's ?tab=rm&ogbl, SPA routes like #inbox), which would
    # otherwise force open-or-switch to spawn a duplicate tab every time.
    u = u.strip()
    for sep in ("#", "?"):
        idx = u.find(sep)
        if idx != -1:
            u = u[:idx]
    u = u.rstrip("/")
    if u.startswith("http://"):
        u = u[7:]
    elif u.startswith("https://"):
        u = u[8:]
    return u.lower()
