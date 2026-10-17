"""P1 pilot: process the six source images and render a review sheet.

Run: PYTHONPATH= <venv>/python tools/resource_art/pilot.py
Outputs go to tools/resource_art/work/ (gitignored, never committed).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import cutout  # noqa: E402
import seamless  # noqa: E402

ROOT = Path(__file__).parent
SRC = ROOT / "sources"
WORK = ROOT / "work"

# Flora (wheat/maize) moved to pilot_flora.py: they are RGBA scatter covers now.
TILES = {
    "fertile_soil": "soil.fertile/soil_try1.png",
}
SPRITES = {
    "cattle": "bio.cattle/cattle_top_v2.png",
    "sheep": "bio.sheep/sheep_top_v1.png",
}
DECALS = {"iron_ore": "ore.iron/iron_try1.png"}
TILE_SIZE = 512
SPRITE_SIZE = 128
# Stand-in for a terrain albedo until the real material is sampled in P2.
GROUND = np.array([0.50, 0.42, 0.31], dtype=np.float32)


def load(path: Path, size: int | None = None) -> np.ndarray:
    im = Image.open(path).convert("RGB")
    if size and im.size != (size, size):
        im = im.resize((size, size), Image.Resampling.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def save(arr: np.ndarray, path: Path) -> None:
    mode = "RGBA" if arr.shape[2] == 4 else "RGB"
    Image.fromarray(np.rint(np.clip(arr, 0, 1) * 255).astype(np.uint8), mode).save(path)


def radial_feather(size: int, inner: float = 0.55, outer: float = 0.98) -> np.ndarray:
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    r = np.hypot(x - size / 2 + 0.5, y - size / 2 + 0.5) / (size / 2)
    t = np.clip((outer - r) / (outer - inner), 0, 1)
    return t * t * (3 - 2 * t)


def over(bg: np.ndarray, fg: np.ndarray, x: int, y: int) -> None:
    h, w = fg.shape[:2]
    a = fg[..., 3:4]
    bg[y:y + h, x:x + w] = bg[y:y + h, x:x + w] * (1 - a) + fg[..., :3] * a


def main() -> int:
    WORK.mkdir(exist_ok=True)
    panels: list[np.ndarray] = []
    for name, rel in TILES.items():
        img = load(SRC / rel, TILE_SIZE)
        before = seamless.wrap_seam_error(img)
        out = seamless.make_seamless(img)
        after = seamless.wrap_seam_error(out)
        print(f"{name:13s} wrap seam ratio {before:5.2f} -> {after:5.2f}")
        save(out, WORK / f"{name}_tile.png")
        big = seamless.tile_preview(out, 2)
        panels.append(np.asarray(
            Image.fromarray(np.rint(big * 255).astype(np.uint8)).resize((512, 512),
                                                                          Image.Resampling.LANCZOS),
            dtype=np.float32) / 255.0)

    canvas = np.tile(GROUND, (512, 512, 1))
    rng = np.random.default_rng(7)
    for name, rel in SPRITES.items():
        rgba = cutout.alpha_bleed(cutout.crop_square(cutout.cut_out(load(SRC / rel))))
        im = Image.fromarray(np.rint(rgba * 255).astype(np.uint8), "RGBA")
        im = im.resize((SPRITE_SIZE, SPRITE_SIZE), Image.Resampling.LANCZOS)
        small = np.asarray(im, dtype=np.float32) / 255.0
        im.save(WORK / f"{name}_sprite.png")
        print(f"{name:13s} sprite {SPRITE_SIZE}px  opaque coverage "
              f"{(small[..., 3] > 0.5).mean():.2f}")
        for _ in range(4):
            s = int(rng.integers(40, 56))
            tiny = np.asarray(im.resize((s, s), Image.Resampling.LANCZOS),
                              dtype=np.float32) / 255.0
            over(canvas, tiny, int(rng.integers(8, 512 - s - 8)),
                 int(rng.integers(8, 512 - s - 8)))
    panels.append(canvas)

    for name, rel in DECALS.items():
        img = load(SRC / rel, TILE_SIZE)
        mask = radial_feather(TILE_SIZE)[..., None]
        rgba = np.concatenate([img, mask], axis=2)
        save(rgba, WORK / f"{name}_decal.png")
        c = np.tile(GROUND, (512, 512, 1))
        over(c, rgba, 0, 0)
        panels.append(c)

    sheet = np.concatenate(panels[:2], axis=1)
    sheet = np.concatenate([sheet, np.concatenate(panels[2:4], axis=1)], axis=0)
    sheet = np.concatenate([sheet, np.concatenate(
        [panels[4], np.tile(GROUND, (512, 512, 1))], axis=1)], axis=0)
    save(sheet, WORK / "pilot_review.png")
    print("wrote", WORK / "pilot_review.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
