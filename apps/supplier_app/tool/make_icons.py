"""Draws the app icon and writes every platform's sizes.

Design ("precision console"): the navy of the sidebar as a rounded square,
three ledger rows, the middle one in the tech-blue accent ending in a dot:
the chosen, lowest valid quote. No gradients, no lettering, legible at 16 px.

    python3 tool/make_icons.py      (from apps/supplier_app)
"""
from pathlib import Path

from PIL import Image, ImageDraw

NAVY = (14, 23, 41, 255)  # Tokens.nav
ACCENT = (40, 95, 240, 255)  # Tokens.accent
ACCENT_LIGHT = (111, 155, 255, 255)  # sidebar logo blue
MUTED = (124, 137, 163, 255)  # Tokens.navInk3
SS = 4  # supersampling for smooth edges


def mark(size: int, inset: float) -> Image.Image:
    """The icon at [size] px; [inset] is the transparent margin (0..0.5)."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x0 = y0 = s * inset
    x1 = y1 = s * (1 - inset)
    w = x1 - x0
    # A faint lighter rim keeps the edge visible on dark taskbars and docks.
    d.rounded_rectangle(
        (x0, y0, x1, y1),
        radius=w * 0.225,
        fill=NAVY,
        outline=(38, 52, 82, 255),
        width=max(SS, round(w * 0.012)),
    )

    def bar(top: float, length: float, colour) -> None:
        h = w * 0.085
        left = x0 + w * 0.22
        y = y0 + w * top
        d.rounded_rectangle(
            (left, y, left + w * length, y + h), radius=h / 2, fill=colour
        )

    bar(0.28, 0.44, MUTED)
    bar(0.4575, 0.40, ACCENT)
    bar(0.635, 0.30, MUTED)
    # The chosen row ends in a dot.
    r = w * 0.075
    cx = x0 + w * (0.22 + 0.40 + 0.115)
    cy = y0 + w * (0.4575 + 0.0425)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=ACCENT_LIGHT)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    # macOS: Apple's grid keeps about 10% transparent margin.
    mac = root / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for n in (16, 32, 64, 128, 256, 512, 1024):
        mark(n, 0.1).save(mac / f"app_icon_{n}.png")
    # Windows: full-bleed rounded square, several sizes in one .ico.
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    mark(256, 0.02).save(
        root / "windows/runner/resources/app_icon.ico",
        sizes=[(n, n) for n in sizes],
    )
    # Android launcher (legacy square icons).
    for folder, n in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        mark(n, 0.04).save(
            root / f"android/app/src/main/res/mipmap-{folder}/ic_launcher.png"
        )
    # Preview sheet for review (not shipped).
    width = 16 + 32 + 64 + 128 + 256 + 60
    sheet = Image.new("RGBA", (width, 512), (243, 245, 248, 255))
    ImageDraw.Draw(sheet).rectangle((0, 256, width, 512), fill=(32, 32, 32, 255))
    for top in (0, 256):
        x = 10
        for n in (16, 32, 64, 128, 256):
            sheet.alpha_composite(mark(n, 0.1), (x, top + 256 - n))
            x += n + 10
    sheet.save("/tmp/icon_preview.png")


if __name__ == "__main__":
    main()
