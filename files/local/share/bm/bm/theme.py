"""Map the user's current omarchy theme into a Textual Theme.

Read ~/.config/omarchy/current/theme/colors.toml and translate the
colors into the Textual color system. Falls back to a built-in theme
if omarchy isn't installed or the file can't be parsed.
"""

from pathlib import Path
import tomllib

from textual.color import Color
from textual.theme import Theme

OMARCHY_COLORS = Path.home() / ".config" / "omarchy" / "current" / "theme" / "colors.toml"
OMARCHY_NAME = Path.home() / ".config" / "omarchy" / "current" / "theme.name"


def load_name() -> str:
    """Return the current omarchy theme name (e.g. 'osaka-jade'), or empty
    string if the marker file isn't present."""
    try:
        return OMARCHY_NAME.read_text().strip()
    except OSError:
        return ""


def load_colors() -> dict:
    """Return the raw omarchy colors.toml contents, or an empty dict if the
    file is missing or unparseable. Use this when you need to reach for a
    specific omarchy color slot directly (e.g. color6 for the help-screen
    key column) — Textual's Theme object doesn't always round-trip arbitrary
    hex values through attributes like .secondary."""
    if not OMARCHY_COLORS.exists():
        return {}
    try:
        return tomllib.loads(OMARCHY_COLORS.read_text())
    except (tomllib.TOMLDecodeError, OSError):
        return {}


def load_theme() -> Theme | None:
    data = load_colors()
    if not data:
        return None

    accent = data.get("accent") or data.get("color4") or "#509475"

    return Theme(
        name="omarchy",
        primary=accent,
        accent=accent,
        foreground=data.get("foreground"),
        background=data.get("background"),
        surface=data.get("color0"),
        panel=data.get("color8"),
        warning=data.get("color3"),
        error=data.get("color1"),
        success=data.get("color2"),
        secondary=data.get("color6"),
        dark=_is_dark(data.get("background")),
    )


def _is_dark(bg_hex: str | None) -> bool:
    """True if the theme background reads as a dark color. Used to flip
    Textual's dark/light flag so its auto-generated variants (muted, lighter/
    darker shades) land on the right side of the contrast line for light
    omarchy themes."""
    if not bg_hex:
        return True
    try:
        color = Color.parse(bg_hex)
    except Exception:
        return True
    # Rec. 709 luminance. <0.5 counts as dark.
    lum = (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b) / 255
    return lum < 0.5


