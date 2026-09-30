"""Export reviewed image-generation masters to each supported platform.

No procedural redrawing: crop transparent padding and resample the original
artwork. Run python3 tool/make_icons.py from apps/supplier_app.
"""
from pathlib import Path

from PIL import Image, ImageDraw


def fit(source: Image.Image, size: int, inset: float) -> Image.Image:
    canvas = Image.new("RGBA", (size, size))
    extent = round(size * (1 - 2 * inset))
    artwork = source.copy()
    artwork.thumbnail((extent, extent), Image.Resampling.LANCZOS)
    canvas.alpha_composite(artwork, ((size - artwork.width) // 2,
                                   (size - artwork.height) // 2))
    return canvas


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    brand = root / "assets/brand"
    launcher = Image.open(brand / "launcher-master-v3.png").convert("RGBA")
    launcher = launcher.crop(launcher.getchannel("A").getbbox())
    header = Image.open(brand / "mark-v3.png").convert("RGBA")
    # Faint isolated generated pixels must not shrink the visible header mark.
    left, top, right, bottom = header.getchannel("A").point(
        lambda value: 255 if value >= 128 else 0).getbbox()
    padding = 8  # retain antialiased edge pixels around the opaque silhouette
    header = header.crop((max(0, left - padding), max(0, top - padding),
                          min(header.width, right + padding),
                          min(header.height, bottom + padding)))
    fit(header, 256, .025).save(brand / "header-mark-v3.png")

    mac = root / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        fit(launcher, size, .1).save(mac / f"app_icon_{size}.png")
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    fit(launcher, 256, .02).save(
        root / "windows/runner/resources/app_icon.ico",
        sizes=[(size, size) for size in sizes],
    )
    for folder, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                         "xxhdpi": 144, "xxxhdpi": 192}.items():
        fit(launcher, size, .04).save(
            root / f"android/app/src/main/res/mipmap-{folder}/ic_launcher.png")

    preview = Image.new("RGBA", (600, 512), (243, 245, 248, 255))
    ImageDraw.Draw(preview).rectangle((0, 256, 600, 512), fill=(22, 28, 39, 255))
    for top in (0, 256):
        left = 16
        for size in (16, 32, 64, 128, 256):
            preview.alpha_composite(fit(launcher, size, .1),
                                    (left, top + (256 - size) // 2))
            left += size + 12
    target = root.parents[1] / "docs/design/icons/launcher-preview.png"
    preview.save(target)
    print("Exported original generated artwork to macOS, Windows and Android.")


if __name__ == "__main__":
    main()
