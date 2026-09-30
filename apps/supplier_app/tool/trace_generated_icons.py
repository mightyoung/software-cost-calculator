"""Convert generated transparent sprite contours into the shared icon catalog.

This preserves the generated silhouettes rather than substituting hand-drawn
icons. Run only after visually reviewing the referenced 4x4 source sheets. OpenCV and
NumPy are authoring tools; neither is a runtime application dependency.
"""
from pathlib import Path
import argparse
import json

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]


def trace_cell(image: Image.Image, slot: int, name: str) -> str:
    column, row = slot % 4, slot // 4
    width, height = image.size
    bounds = (
        round(column * width / 4), round(row * height / 4),
        round((column + 1) * width / 4), round((row + 1) * height / 4),
    )
    # Alpha is geometry: both dark and light source colours trace identically.
    alpha = np.asarray(image.convert("RGBA"))[bounds[1]:bounds[3], bounds[0]:bounds[2], 3]
    mask = np.uint8(alpha >= 128) * 255
    contours, _ = cv2.findContours(mask, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)
    contours = [c for c in contours if abs(cv2.contourArea(c)) >= 4]
    if not contours:
        raise ValueError(f"{name}: empty cell")
    points = np.concatenate(contours)
    x, y, w, h = cv2.boundingRect(points)
    if x < 3 or y < 3 or x + w > mask.shape[1] - 3 or y + h > mask.shape[0] - 3:
        raise ValueError(f"{name}: geometry touches cell edge; review grid placement")
    if w * h > mask.size * .75:
        raise ValueError(f"{name}: source is opaque; a transparent sprite is required")
    scale = 19.5 / max(w, h)
    dx, dy = (24 - w * scale) / 2, (24 - h * scale) / 2
    paths = []
    for contour in contours:
        simplified = cv2.approxPolyDP(contour, .3, True).reshape(-1, 2)
        if len(simplified) < 3:
            continue
        coordinates = [(dx + (px - x) * scale, dy + (py - y) * scale)
                       for px, py in simplified]
        paths.append(" ".join(
            f"{'M' if i == 0 else 'L'} {px:.3f} {py:.3f}"
            for i, (px, py) in enumerate(coordinates)) + " Z")
    return " ".join(paths)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    catalog = json.loads((ROOT / "docs/design/icons/catalog.json").read_text())
    images = {}
    for index, item in enumerate(catalog):
        source = item.get("source", f"output/imagegen/icons/sheet-{index // 16 + 1}.png#{index % 16}")
        filename, slot = source.rsplit("#", 1)
        filename = Path(filename).name
        if filename not in images:
            images[filename] = Image.open(args.sources / filename)
        item["path"] = trace_cell(images[filename], int(slot), item["id"])
        item["paint"] = "fill"
        item["source"] = source
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(f"Converted {len(catalog)} generated silhouettes; review {args.out} before replacing catalog.")


if __name__ == "__main__":
    main()
