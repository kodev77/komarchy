from pathlib import Path
from urllib.parse import urlparse
import hashlib
import httpx

from .paths import FAVICON_CACHE, ensure_dirs

FALLBACK_GLYPH = "\uf0ac"  # Nerd Font globe


def domain_of(url: str) -> str:
    try:
        host = urlparse(url).hostname or ""
    except ValueError:
        host = ""
    return host.lower()


def cache_path(url: str) -> Path:
    ensure_dirs()
    host = domain_of(url)
    if host:
        key = host
    else:
        key = hashlib.sha1(url.encode()).hexdigest()[:16]
    return FAVICON_CACHE / f"{key}.png"


def fetch(url: str, explicit_favicon: str | None = None) -> Path | None:
    """Return a cached favicon path for `url`. Fetches on miss."""
    path = cache_path(url)
    if path.exists() and path.stat().st_size > 0:
        return path

    candidates = []
    if explicit_favicon:
        candidates.append(explicit_favicon)
    host = domain_of(url)
    if host:
        candidates.append(f"https://{host}/apple-touch-icon.png")
        candidates.append(f"https://www.google.com/s2/favicons?domain={host}&sz=128")

    for candidate in candidates:
        if _download(candidate, path):
            return path
    return None


def _download(src: str, dest: Path) -> bool:
    try:
        with httpx.Client(follow_redirects=True, timeout=4.0) as c:
            r = c.get(src)
            if r.status_code != 200 or not r.content:
                return False
            dest.write_bytes(r.content)
            return True
    except httpx.HTTPError:
        return False
