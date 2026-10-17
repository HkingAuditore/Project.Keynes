"""Turn raw generated sheets into engine-ready PNGs + manifest.

Run: PYTHONPATH= <venv>/python tools/resource_art/build.py [id ...]

Output (res://assets/textures/resource_art/):
  flora/<id>_dense.png, flora/<id>_sparse.png   512px tileable RGBA ground cover
  fauna/<id>.png                                 sprite atlas, 3 columns x N rows
  manifest.json                                  ids, sizes, cell grid, mean colour
Flora tiles are straight-alpha so the terrain shows through the gaps.
"""
from __future__ import annotations

import json
import re
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import cutout  # noqa: E402
import natural  # noqa: E402

HERE = Path(__file__).parent
SRC = HERE / "sources"
INBOX = SRC / "_inbox"
OUT = HERE.parent.parent / "Project" / "project-keynes" / "assets" / "textures" / "resource_art"
CELL = 128           # fauna atlas cell edge (px)
COLS = 3
MAX_ROWS = 4         # 12 sprites max per species
TILE = 512
# id -> (inbox tag, extra source files, plant diameter px in a 512 tile)
FLORA = {
    "bio.wheat": (None, ["bio.wheat/wheat_plants_v1_sideview.png"], 120),
    "bio.maize": (None, ["bio.maize/maize_side_v3.png"], 170),
    "bio.rice": ("bio_rice", [], 120), "bio.potato": ("bio_potato", [], 130),
    "bio.cotton": ("bio_cotton", [], 120), "bio.flax": ("bio_flax", [], 110),
    "bio.spice": ("bio_spice", [], 120), "bio.rubber": ("bio_rubber", [], 150),
    "bio.silkworm": ("bio_silkworm", [], 130), "bio.reed": ("bio_reed", [], 140),
    "bio.bast_fiber": ("bio_bast_fiber", [], 140),
    "bio.dye_plant": ("bio_dye_plant", [], 120),
    "bio.medicinal_herb": ("bio_medicinal_herb", [], 110),
}
FAUNA = {
    "bio.cattle": ("bio_cattle", ["bio.cattle/cattle_top_v2.png"]),
    "bio.sheep": ("bio_sheep", ["bio.sheep/sheep_top_v1.png"]),
    "bio.goat": ("bio_goat", []), "bio.pig": ("bio_pig", []),
    "bio.horse": ("bio_horse", []), "bio.camel": ("bio_camel", []),
    "bio.yak": ("bio_yak", []),
    "marine_fish": ("marine_fish", []), "freshwater_fish": ("freshwater_fish", []),
}


def sheets_for(tag: str | None, extra: list[str]) -> list[Path]:
    files = [SRC / e for e in extra]
    if tag:
        # "bio_camel" also collects bio_camel2 / bio_camel3 variants.
        pat = re.compile(rf"^{re.escape(tag)}\d*_sheet")
        files += sorted(f for f in INBOX.glob("*.png") if pat.match(f.name))
    return files


def load_sprites(files: list[Path]) -> list[np.ndarray]:
    out: list[np.ndarray] = []
    for f in files:
        img = np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) / 255.0
        try:
            out += cutout.cut_out_many(img)
        except ValueError:
            print("  skip (nothing cut):", f.name)
    return drop_merged(out)


def drop_merged(sprites: list[np.ndarray]) -> list[np.ndarray]:
    if len(sprites) < 3:
        return sprites
    areas = np.array([s.shape[0] * s.shape[1] for s in sprites], dtype=np.float32)
    med = float(np.median(areas))
    return [s for s, a in zip(sprites, areas) if a < med * 1.5]


def u8(a: np.ndarray) -> np.ndarray:
    return np.rint(np.clip(a, 0, 1) * 255).astype(np.uint8)


def mean_color(t: np.ndarray) -> list[float]:
    w = t[..., 3:4]
    return [round(float((t[..., :3] * w).sum((0, 1))[i] / max(w.sum(), 1e-6)), 3)
            for i in range(3)]


def build_flora(pid: str, tag, extra, diameter: int) -> dict | None:
    sprites = load_sprites(sheets_for(tag, extra))
    if len(sprites) < 3:
        print(f"{pid}: only {len(sprites)} sprites, skipped")
        return None
    d = OUT / "flora"
    d.mkdir(parents=True, exist_ok=True)
    seed = zlib.crc32(pid.encode()) % 997
    info = {"kind": "flora", "sprites": len(sprites)}
    for name, ab in (("dense", 0.70), ("sparse", 0.30)):
        t = natural.natural_cover(sprites, TILE, diameter, abundance=ab, seed=seed)
        Image.fromarray(u8(t), "RGBA").save(d / f"{pid}_{name}.png", optimize=True)
        info[name] = f"flora/{pid}_{name}.png"
        info[f"{name}_cover"] = round(float((t[..., 3] > 0.5).mean()), 3)
        if name == "dense":
            info["color"] = mean_color(t)
    print(f"{pid}: {info['sprites']} sprites, dense cover {info['dense_cover']}")
    return info


def build_fauna(pid: str, tag, extra) -> dict | None:
    sprites = load_sprites(sheets_for(tag, extra))
    if not sprites:
        print(f"{pid}: no sprites, skipped")
        return None
    sprites = sprites[:12]
    rows = (len(sprites) + COLS - 1) // COLS
    # Always 4 rows so every species shares one Texture2DArray size.
    atlas = np.zeros((MAX_ROWS * CELL, COLS * CELL, 4), dtype=np.float32)
    # One shared scale per species keeps relative sizes honest; fit the longest.
    longest = max(max(s.shape[:2]) for s in sprites)
    k = (CELL - 8) / longest
    for i, s in enumerate(sprites):
        h, w = s.shape[:2]
        im = Image.fromarray(u8(s), "RGBA").resize(
            (max(1, int(w * k)), max(1, int(h * k))), Image.Resampling.LANCZOS)
        a = np.asarray(im, dtype=np.float32) / 255.0
        y0 = (i // COLS) * CELL + (CELL - a.shape[0]) // 2
        x0 = (i % COLS) * CELL + (CELL - a.shape[1]) // 2
        atlas[y0:y0 + a.shape[0], x0:x0 + a.shape[1]] = a
    atlas = cutout.alpha_bleed(atlas)
    d = OUT / "fauna"
    d.mkdir(parents=True, exist_ok=True)
    Image.fromarray(u8(atlas), "RGBA").save(d / f"{pid}.png", optimize=True)
    print(f"{pid}: {len(sprites)} sprites -> {rows}x{COLS} atlas")
    return {"kind": "fauna", "file": f"fauna/{pid}.png", "cell": CELL, "cols": COLS,
            "rows": rows, "count": len(sprites), "color": mean_color(atlas)}


def main() -> int:
    want = set(sys.argv[1:])
    OUT.mkdir(parents=True, exist_ok=True)
    mf_path = OUT / "manifest.json"
    manifest = json.loads(mf_path.read_text("utf-8")) if mf_path.exists() else {}
    for pid, (tag, extra, diam) in FLORA.items():
        if not want or pid in want:
            r = build_flora(pid, tag, extra, diam)
            if r:
                manifest[pid] = r
    for pid, (tag, extra) in FAUNA.items():
        if not want or pid in want:
            r = build_fauna(pid, tag, extra)
            if r:
                manifest[pid] = r
    mf_path.write_text(json.dumps(manifest, indent=1, sort_keys=True), "utf-8")
    print("manifest:", len(manifest), "entries ->", mf_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
