"""Slice the generated technology-tree papercut sheets into small runtime PNGs.

Usage:
  python tools/technology_tree/slice_technology_tree_art.py \
      <plates.png> <emblems.png> <scrolls.png> <backdrop.png>

The four ImageGen sources are copied to assets/ui/technology_tree_v1/source/.
Sheets already carry real alpha; components are split by alpha connectivity
in reading order and downsampled once so the runtime footprint stays small.
"""
from __future__ import annotations

import pathlib
import shutil
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/ui/technology_tree_v1"

PLATES = ["card_known", "card_unknown", "card_selected", "card_milestone"]
EMBLEMS = ["domain_agriculture", "domain_engineering", "domain_science",
           "domain_society", "state_completed", "state_queued",
           "state_pending", "state_unknown"]
SCROLLS = ["era_scroll", "lane_ribbon", "lane_strip"]
# Longest side after downsampling (pixels).
TARGET = {
    "card_known": 384, "card_unknown": 384, "card_selected": 384,
    "card_milestone": 448, "era_scroll": 768, "lane_ribbon": 320,
    "lane_strip": 384,
}
EMBLEM_SIZE = 64
BACKDROP_SIZE = 512


def components(path: str) -> list[tuple[slice, slice]]:
    rgba = np.asarray(Image.open(path).convert("RGBA"))
    mask = ndimage.binary_opening(rgba[..., 3] > 24, iterations=2)
    labels, _ = ndimage.label(mask)
    boxes = [box for box in ndimage.find_objects(labels)
             if (box[0].stop - box[0].start) * (box[1].stop - box[1].start) > 4000]
    # Reading order: rows by vertical centre, then left to right.
    boxes.sort(key=lambda b: (round((b[0].start + b[0].stop) / 2 / 120), b[1].start))
    return boxes


def crop(path: str, box, pad: int = 4) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    y0 = max(0, box[0].start - pad)
    x0 = max(0, box[1].start - pad)
    y1 = min(image.height, box[0].stop + pad)
    x1 = min(image.width, box[1].stop + pad)
    return image.crop((x0, y0, x1, y1))


def fit(image: Image.Image, longest: int) -> Image.Image:
    scale = longest / max(image.size)
    if scale >= 1.0:
        return image
    size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
    return image.resize(size, Image.LANCZOS)


def split(path: str, names: list[str], sizer) -> None:
    boxes = components(path)
    if len(boxes) < len(names):
        boxes = equal_columns(path, len(names))
    if len(boxes) < len(names):
        raise SystemExit(f"{path}: expected {len(names)} items, found {len(boxes)}")
    for name, box in zip(names, boxes):
        out = sizer(name, crop(path, box))
        out.save(OUT / f"{name}.png", optimize=True)
        print(f"{name}: {out.width}x{out.height}")


def equal_columns(path: str, count: int) -> list[tuple[slice, slice]]:
    """Fallback for a single row whose soft shadows touch: cut at the emptiest
    column near each nominal split, then tighten every cell to its alpha."""
    alpha = np.asarray(Image.open(path).convert("RGBA"))[..., 3] > 24
    cols = np.where(alpha.any(axis=0))[0]
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    profile = alpha[:, x0:x1].sum(axis=0)
    width = x1 - x0
    cuts = [0]
    for k in range(1, count):
        nominal = int(width * k / count)
        lo, hi = max(0, nominal - 40), min(width, nominal + 40)
        cuts.append(lo + int(np.argmin(profile[lo:hi])))
    cuts.append(width)
    boxes = []
    for k in range(count):
        cell = alpha[:, x0 + cuts[k]:x0 + cuts[k + 1]]
        rows = np.where(cell.any(axis=1))[0]
        sub = np.where(cell.any(axis=0))[0]
        boxes.append((slice(int(rows[0]), int(rows[-1]) + 1),
                      slice(x0 + cuts[k] + int(sub[0]), x0 + cuts[k] + int(sub[-1]) + 1)))
    return boxes


def main(plates: str, emblems: str, scrolls: str, backdrop: str) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    split(plates, PLATES, lambda n, im: fit(im, TARGET[n]))
    split(emblems, EMBLEMS, lambda n, im: fit(im, EMBLEM_SIZE))
    split(scrolls, SCROLLS, lambda n, im: fit(im, TARGET[n]))
    tile = Image.open(backdrop).convert("RGB").resize(
        (BACKDROP_SIZE, BACKDROP_SIZE), Image.LANCZOS)
    tile.save(OUT / "canvas_paper.png", optimize=True)
    print(f"canvas_paper: {BACKDROP_SIZE}x{BACKDROP_SIZE}")
    source = OUT / "source"
    source.mkdir(exist_ok=True)
    for name, path in zip(["plates", "emblems", "scrolls", "backdrop"],
                          [plates, emblems, scrolls, backdrop]):
        shutil.copyfile(path, source / f"technology_tree_{name}_v1.png")


if __name__ == "__main__":
    main(*sys.argv[1:5])
