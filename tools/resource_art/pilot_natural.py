"""Before/after sheet: stamped tile vs natural cover.

Columns: old dense tile | new abundance 0.30 | new abundance 0.65.
Run: PYTHONPATH= <venv>/python tools/resource_art/pilot_natural.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import cutout  # noqa: E402
import natural  # noqa: E402
import scatter  # noqa: E402

ROOT = Path(__file__).parent
SRC, WORK = ROOT / "sources", ROOT / "work"
GROUND = np.array([0.50, 0.42, 0.31], dtype=np.float32)
SPECIES = {"wheat": ("bio.wheat/wheat_plants_v1_sideview.png", 120),
           "maize": ("bio.maize/maize_side_v3.png", 170)}


def drop_merged(sprites: list[np.ndarray]) -> list[np.ndarray]:
    """Drop sprites whose bbox area is far above the median (fused neighbours)."""
    areas = np.array([s.shape[0] * s.shape[1] for s in sprites], dtype=np.float32)
    med = float(np.median(areas))
    return [s for s, a in zip(sprites, areas) if a < med * 1.5]


def comp(t: np.ndarray) -> np.ndarray:
    bg = np.tile(GROUND, t.shape[:2] + (1,))
    return bg * (1 - t[..., 3:4]) + t[..., :3] * t[..., 3:4]


def u8(a: np.ndarray) -> np.ndarray:
    return np.rint(np.clip(a, 0, 1) * 255).astype(np.uint8)


def main() -> int:
    rows = []
    for name, (rel, diam) in SPECIES.items():
        img = np.asarray(Image.open(SRC / rel).convert("RGB"), dtype=np.float32) / 255.0
        sprites = drop_merged(cutout.cut_out_many(img))
        print(name, "usable sprites:", len(sprites))
        old = np.asarray(Image.open(WORK / f"{name}_cover_dense.png"),
                         dtype=np.float32) / 255.0
        cols = [comp(old)]
        for ab in (0.30, 0.65):
            t = natural.natural_cover(sprites, 512, diam, abundance=ab, seed=5)
            Image.fromarray(u8(t), "RGBA").save(WORK / f"{name}_natural_{int(ab*100)}.png")
            print(f"{name} abundance {ab}: cover {scatter.coverage(t):.2f} "
                  f"wrap alpha ratio {scatter.wrap_alpha_error(t):.2f}")
            cols.append(comp(t))
        rows.append(np.concatenate(cols, axis=1))
    sheet = np.concatenate(rows, axis=0)
    Image.fromarray(u8(sheet), "RGB").save(WORK / "natural_review.png")
    print("wrote", WORK / "natural_review.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
