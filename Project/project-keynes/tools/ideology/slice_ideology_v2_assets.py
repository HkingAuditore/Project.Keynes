"""Slice the authored ideology V2 art sheets into runtime-sized transparent assets.

The source sheets are kept under assets/ui/ideology_v2/source/ for provenance.
All names and crop regions are pinned so rerunning the slicer is deterministic.
"""
from __future__ import annotations

import pathlib
import shutil
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/ui/ideology_v2"

FRAME_CROPS = {
    "frame_common": (32, 60, 594, 786),
    "frame_rare": (650, 58, 1232, 812),
    "frame_legendary": (1258, 0, 1884, 820),
}

SCHOOL_CROPS = {
    "school_agrarian": (4, 3, 442, 420),
    "school_commerce": (447, 35, 884, 421),
    "school_learning": (900, 6, 1324, 422),
    "school_mobilization": (2, 420, 448, 814),
    "school_industry": (448, 426, 892, 810),
    "school_harmony": (890, 427, 1325, 811),
}

# Scattered single decals in the FX sheet. Each crop includes its own paper
# fringe; transparent gaps remain transparent.
FX_CROPS = {
    "fx_paper_burst": (12, 24, 506, 490),
    "fx_ribbon_sweep": (510, 16, 1028, 493),
    "fx_ink_ring": (1034, 8, 1530, 500),
    "fx_ink_stroke": (10, 514, 505, 1010),
    "fx_sun_burst": (514, 505, 1030, 1010),
    "fx_red_seal": (1034, 490, 1530, 1024),
}


def _crop_rgba(image: Image.Image, box: tuple[int, int, int, int], pad: int = 4) -> Image.Image:
    x0, y0, x1, y1 = box
    x0 = max(0, x0 - pad)
    y0 = max(0, y0 - pad)
    x1 = min(image.width, x1 + pad)
    y1 = min(image.height, y1 + pad)
    return image.crop((x0, y0, x1, y1))


def _trim_alpha(image: Image.Image, alpha_cutoff: int = 8) -> Image.Image:
    rgba = np.asarray(image.convert("RGBA"))
    mask = rgba[:, :, 3] > alpha_cutoff
    if not mask.any():
        return image
    ys, xs = np.where(mask)
    pad = 3
    box = (
        max(0, int(xs.min()) - pad),
        max(0, int(ys.min()) - pad),
        min(image.width, int(xs.max()) + pad + 1),
        min(image.height, int(ys.max()) + pad + 1),
    )
    return image.crop(box)


def _clean_white_fringe(image: Image.Image) -> Image.Image:
    """Remove light matte pixels while preserving the authored paper fringe."""
    rgba = np.asarray(image.convert("RGBA")).copy()
    rgb = rgba[:, :, :3].astype(np.int16)
    alpha = rgba[:, :, 3].astype(np.float32) / 255.0
    # The source sheet was generated with an opaque near-white backdrop that was
    # keyed to alpha. White specks embedded in the edge remain fully opaque; they
    # are legitimate paper fibres, so only soften extreme white on translucent
    # antialias pixels.
    translucent_white = (alpha > 0.0) & (alpha < 0.98) & (rgb.min(axis=2) > 238)
    rgba[translucent_white, 3] = (rgba[translucent_white, 3].astype(np.float32) * 0.35).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def main() -> None:
    source_dir = OUT / "source"
    source_dir.mkdir(parents=True, exist_ok=True)
    frame_source = source_dir / "ideology_frames_source_v2.png"
    sigil_source = source_dir / "ideology_sigils_source_v2.png"
    fx_source = source_dir / "ideology_fx_source_v2.png"
    for source in (frame_source, sigil_source, fx_source):
        if not source.exists():
            raise SystemExit(f"Missing source sheet: {source}")
    frames = Image.open(frame_source).convert("RGBA")
    sigils = Image.open(sigil_source).convert("RGBA")
    fx = Image.open(fx_source).convert("RGBA")

    written: list[tuple[str, int, int]] = []

    def save(name: str, image: Image.Image) -> None:
        dest = OUT / f"{name}.png"
        image.save(dest)
        written.append((name, image.width, image.height))

    for name, box in FRAME_CROPS.items():
        save(name, _trim_alpha(_clean_white_fringe(_crop_rgba(frames, box, 2))))
    for name, box in SCHOOL_CROPS.items():
        save(name, _trim_alpha(_clean_white_fringe(_crop_rgba(sigils, box, 2))))
    for name, box in FX_CROPS.items():
        save(name, _trim_alpha(_clean_white_fringe(_crop_rgba(fx, box, 2))))

    for name, width, height in written:
        print(f"{name}: {width}x{height}")


if __name__ == "__main__":
    main()
