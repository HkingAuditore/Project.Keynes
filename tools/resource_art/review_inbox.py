"""Contact sheet + cut-out stats for every PNG in sources/_inbox.

Usage: python review_inbox.py [prefix ...]   (no prefix = everything)
Writes work/inbox_review.png and prints, per sheet, how many sprites the
magenta cut-out finds plus their size spread (merged neighbours stand out).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import cutout

HERE = Path(__file__).parent
INBOX = HERE / "sources" / "_inbox"
CELL = 380


def tag_of(p: Path) -> str:
    # "bio_rice_sheet__Game_art..." -> "bio_rice"; "bio_rice_sheet" -> "bio_rice"
    return p.name.split("_sheet")[0].split("__")[0]


def main() -> None:
    prefixes = sys.argv[1:]
    files = sorted(f for f in INBOX.glob("*.png")
                   if not prefixes or any(f.name.startswith(p) for p in prefixes))
    if not files:
        print("inbox empty")
        return
    cols = 4
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * CELL, rows * (CELL + 22)), (235, 235, 235))
    draw = ImageDraw.Draw(sheet)
    for i, f in enumerate(files):
        im = Image.open(f).convert("RGB")
        arr = np.asarray(im, dtype=np.float32) / 255.0
        try:
            sp = cutout.cut_out_many(arr)
            areas = np.array([s.shape[0] * s.shape[1] for s in sp], dtype=np.float32)
            med = float(np.median(areas)) if len(sp) else 0.0
            merged = int((areas > 1.5 * med).sum()) if len(sp) else 0
            info = f"{len(sp)} sprites, merged?={merged}"
        except Exception as e:  # noqa: BLE001 - report and keep going
            info = f"cutout failed: {e}"
        print(f"{tag_of(f):28s} {info}")
        x, y = (i % cols) * CELL, (i // cols) * (CELL + 22)
        sheet.paste(im.resize((CELL, CELL), Image.LANCZOS), (x, y + 22))
        draw.text((x + 4, y + 4), f"{tag_of(f)}  {info}", fill=(0, 0, 0))
    out = HERE / "work" / "inbox_review.png"
    out.parent.mkdir(exist_ok=True)
    sheet.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
