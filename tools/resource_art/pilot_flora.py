"""P1 flora pilot v2: RGBA ground cover from isolated plant sheets.

Run: PYTHONPATH= <venv>/python tools/resource_art/pilot_flora.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import cutout  # noqa: E402
import scatter  # noqa: E402

ROOT = Path(__file__).parent
SRC = ROOT / "sources"
WORK = ROOT / "work"
GROUND = np.array([0.50, 0.42, 0.31], dtype=np.float32)
SPECIES = {
    "wheat": ("bio.wheat/wheat_plants_v2.png", 150),
    "maize": ("bio.maize/maize_plants_v2.png", 132),
}


def load(rel: str) -> np.ndarray:
    return np.asarray(Image.open(SRC / rel).convert("RGB"), dtype=np.float32) / 255.0


def composite(tile: np.ndarray, reps: int = 2) -> np.ndarray:
    big = np.tile(tile, (reps, reps, 1))
    bg = np.tile(GROUND, big.shape[:2] + (1,))
    return bg * (1 - big[..., 3:4]) + big[..., :3] * big[..., 3:4]


def to_u8(a: np.ndarray) -> np.ndarray:
    return np.rint(np.clip(a, 0, 1) * 255).astype(np.uint8)


def main() -> int:
    WORK.mkdir(exist_ok=True)
    rows = []
    for name, (rel, diameter) in SPECIES.items():
        sprites = cutout.cut_out_many(load(rel))
        print(f"{name}: {len(sprites)} plants cut out")
        tiles = []
        for label, cover, seed in (("sparse", 0.28, 3), ("dense", 0.70, 4)):
            t = scatter.scatter(sprites, tile=512, diameter=diameter,
                                spacing=0.42, target_cover=cover, seed=seed)
            Image.fromarray(to_u8(t), "RGBA").save(WORK / f"{name}_cover_{label}.png")
            print(f"  {label:6s} coverage {scatter.coverage(t):.2f}  "
                  f"wrap alpha ratio {scatter.wrap_alpha_error(t):.2f}")
            tiles.append(composite(t, 1))
        rows.append(np.concatenate(tiles, axis=1))
    sheet = np.concatenate(rows, axis=0)
    # Hard edge between the two halves of the sheet would hide wrap seams,
    # so also write a 2x2 repeat of the dense wheat tile.
    rep = composite(np.asarray(Image.open(WORK / "wheat_cover_dense.png"),
                               dtype=np.float32) / 255.0, 2)
    Image.fromarray(to_u8(sheet), "RGB").save(WORK / "flora_review.png")
    Image.fromarray(to_u8(rep), "RGB").resize((768, 768)).save(WORK / "wheat_repeat_check.png")
    print("wrote", WORK / "flora_review.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
