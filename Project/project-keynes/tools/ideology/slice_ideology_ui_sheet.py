"""Slice the generated ideology UI asset sheet into transparent PNGs.

Usage: python tools/ideology/slice_ideology_ui_sheet.py <sheet.png>
The sheet is kept under assets/ui/ideology_v1/source/ for provenance.
"""
from __future__ import annotations

import pathlib
import shutil
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/ui/ideology_v1"
# Reading order: row 1 cards, row 2 emblems, row 3 niches/seal/scroll/ink/confetti.
ROW_NAMES = [
    ["card_frame_common", "card_frame_rare", "card_frame_legendary", "card_back"],
    ["school_agrarian", "school_commerce", "school_learning",
     "school_mobilization", "school_industry", "school_harmony"],
    ["slot_niche", "spirit_niche", "wax_seal", "scroll_bar"],
]
# Scattered decals are cropped from fixed sheet regions (y0, y1, x0, x1).
FIXED_REGIONS = {
    "ink_splash": (800, 1000, 860, 1090),
    "paper_confetti": (815, 990, 1160, 1475),
}


def main(sheet_path: str) -> None:
    image = Image.open(sheet_path).convert("RGB")
    rgb = np.asarray(image).astype(np.int32)
    background = np.array([251, 250, 246])
    distance = np.abs(rgb - background).sum(axis=2)
    near_bg = distance < 22
    # Background is the near-white region connected to the sheet border.
    labels, _ = ndimage.label(near_bg)
    border = set(np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]])))
    border.discard(0)
    bg_mask = np.isin(labels, list(border))
    foreground = ndimage.binary_opening(~bg_mask, iterations=2)
    comp, count = ndimage.label(foreground)
    boxes = ndimage.find_objects(comp)
    items = []
    for index, box in enumerate(boxes):
        height = box[0].stop - box[0].start
        width = box[1].stop - box[1].start
        if height * width < 900:
            continue
        items.append((box, index + 1))
    big = [item for item in items if (item[0][0].stop - item[0][0].start) > 60
           and (item[0][1].stop - item[0][1].start) > 60]
    small = [item for item in items if item not in big]
    # Group big items into rows by vertical centre.
    big.sort(key=lambda item: (item[0][0].start + item[0][0].stop) / 2)
    rows: list[list] = []
    for item in big:
        centre = (item[0][0].start + item[0][0].stop) / 2
        if rows and abs(centre - rows[-1][0]) < 120:
            rows[-1][1].append(item)
        else:
            rows.append([centre, [item]])
    OUT.mkdir(parents=True, exist_ok=True)
    alpha_full = (~bg_mask).astype(np.uint8) * 255
    alpha_full = ndimage.gaussian_filter(alpha_full.astype(float), 0.8).clip(0, 255).astype(np.uint8)
    rgba = np.dstack([rgb.astype(np.uint8), alpha_full])
    written = []

    def save(name: str, y0: int, y1: int, x0: int, x1: int) -> None:
        y0, x0 = max(0, y0), max(0, x0)
        y1, x1 = min(rgba.shape[0], y1), min(rgba.shape[1], x1)
        Image.fromarray(rgba[y0:y1, x0:x1]).save(OUT / f"{name}.png")
        written.append((name, x1 - x0, y1 - y0))

    for row_index, (_centre, row_items) in enumerate(rows[:len(ROW_NAMES)]):
        row_items.sort(key=lambda item: item[0][1].start)
        names = ROW_NAMES[row_index]
        if len(row_items) < len(names) and row_index == 1:
            # Emblem shadows touch: split the merged strip into equal columns,
            # snapping each cut to the emptiest column near the nominal cut.
            box = max(row_items, key=lambda item: item[0][1].stop - item[0][1].start)[0]
            ys, xs = box
            profile = (~bg_mask[ys, xs]).sum(axis=0)
            width = xs.stop - xs.start
            cuts = [0]
            for k in range(1, len(names)):
                nominal = int(width * k / len(names))
                window = slice(max(0, nominal - 40), min(width, nominal + 40))
                cuts.append(window.start + int(np.argmin(profile[window])))
            cuts.append(width)
            for col, name in enumerate(names):
                save(name, ys.start - 3, ys.stop + 3, xs.start + cuts[col], xs.start + cuts[col + 1])
            continue
        for col, (box, _label) in enumerate(row_items[:len(names)]):
            save(names[col], box[0].start - 3, box[0].stop + 3, box[1].start - 3, box[1].stop + 3)
    for name, (y0, y1, x0, x1) in FIXED_REGIONS.items():
        save(name, y0, y1, x0, x1)
    source_dir = OUT / "source"
    source_dir.mkdir(exist_ok=True)
    shutil.copyfile(sheet_path, source_dir / "ideology_asset_sheet_v1.png")
    for name, width, height in written:
        print(f"{name}: {width}x{height}")


if __name__ == "__main__":
    main(sys.argv[1])
