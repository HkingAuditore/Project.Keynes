"""Derive the country-affairs dossier shell bitmaps from the family dossier art.

Outputs (assets/ui/dossier_shell/):
  spine_leather.png  hinge-free leather spine, used as a 9-slice with a tiled centre
  page_frame.png     parchment page with gold border, rules removed, used as a 9-slice
  hinge.png          one brass hinge on a transparent background, placed on the seam
  nav_tab_*.png      downscaled ribbon tabs so 9-slice margins stay in screen pixels

Run from the Godot project root:  py -3.13 tools/ui/build_dossier_shell_bitmaps.py
"""

from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets/ui/family_workspace/bitmap/dossier_background_v2.png"
OUT = ROOT / "assets/ui/dossier_shell"
NAV_ATLAS = ROOT / "assets/ui/family_workspace/bitmap/nav_tabs_atlas_v1.png"
NAV_TAB_HEIGHT = 72

HINGE_ROWS = (216, 609, 1002)
HINGE_HALF_HEIGHT = 58
CLEAN_LEATHER_ROW = 330
FEATHER = 10


def _replace_band(pixels: np.ndarray, target_top: int, source_top: int, height: int,
                  x0: int, x1: int) -> None:
    band = pixels[source_top:source_top + height, x0:x1].astype(np.float32)
    dest = pixels[target_top:target_top + height, x0:x1].astype(np.float32)
    weights = np.ones((height, 1, 1), np.float32)
    ramp = np.linspace(0.0, 1.0, FEATHER, dtype=np.float32)
    weights[:FEATHER, 0, 0] = ramp
    weights[-FEATHER:, 0, 0] = ramp[::-1]
    mixed = dest * (1.0 - weights) + band * weights
    pixels[target_top:target_top + height, x0:x1] = mixed.astype(np.uint8)


def build_spine(source: np.ndarray) -> Image.Image:
    pixels = source.copy()
    height = HINGE_HALF_HEIGHT * 2
    for row in HINGE_ROWS:
        _replace_band(pixels, row - HINGE_HALF_HEIGHT, CLEAN_LEATHER_ROW, height, 96, 246)
    return Image.fromarray(pixels[16:1240, 20:244])


def build_page(source: np.ndarray) -> Image.Image:
    pixels = source.copy()
    for rule_row in (140, 1119):
        _replace_band(pixels, rule_row - 15, rule_row - 50, 30, 300, 1160)
    height = HINGE_HALF_HEIGHT * 2
    for row in HINGE_ROWS:
        _replace_band(pixels, row - HINGE_HALF_HEIGHT, CLEAN_LEATHER_ROW, height, 236, 300)
    page = Image.fromarray(pixels[16:1240, 236:1240])
    return page.resize((page.width // 2, page.height // 2), Image.LANCZOS)


def build_hinge(source: np.ndarray) -> Image.Image:
    crop = source[150:285, 118:300].copy()
    rgb = crop[..., :3].astype(np.float32) / 255.0
    maxc = rgb.max(axis=2)
    minc = rgb.min(axis=2)
    sat = np.where(maxc > 0, (maxc - minc) / np.maximum(maxc, 1e-6), 0.0)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    warm = (r >= g) & (g >= b * 0.95)
    brass = warm & (sat > 0.32) & (maxc > 0.36)
    brass = ndimage.binary_opening(brass, structure=np.ones((5, 5)))
    labels, count = ndimage.label(brass)
    if count == 0:
        raise SystemExit("hinge mask is empty")
    sizes = ndimage.sum(brass, labels, range(1, count + 1))
    keep = np.zeros_like(brass)
    for index, size in enumerate(sizes, start=1):
        if size >= sizes.max() * 0.08:
            keep |= labels == index
    keep = ndimage.binary_closing(keep, structure=np.ones((15, 15)))
    keep = ndimage.binary_fill_holes(keep)
    outline = ndimage.binary_dilation(keep, iterations=3)
    alpha = ndimage.gaussian_filter(outline.astype(np.float32), 0.9)
    crop[..., 3] = np.clip(alpha * 255.0, 0, 255).astype(np.uint8)
    ys, xs = np.nonzero(crop[..., 3] > 8)
    crop = crop[max(0, ys.min() - 2):ys.max() + 3, max(0, xs.min() - 2):xs.max() + 3]
    hinge = Image.fromarray(crop)
    return hinge.resize((round(hinge.width * 0.6), round(hinge.height * 0.6)), Image.LANCZOS)


def build_nav_tabs() -> dict:
    atlas = Image.open(NAV_ATLAS).convert("RGBA")
    tabs = {}
    for name, region in (("nav_tab_normal.png", (40, 160, 920, 660)),
                         ("nav_tab_active.png", (995, 160, 1875, 660))):
        tab = atlas.crop(region)
        bbox = tab.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
        if bbox:
            tab = tab.crop(bbox)
        scale = NAV_TAB_HEIGHT / tab.height
        tabs[name] = tab.resize((round(tab.width * scale), NAV_TAB_HEIGHT), Image.LANCZOS)
    return tabs


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    source = np.array(Image.open(SOURCE).convert("RGBA"))
    build_spine(source).save(OUT / "spine_leather.png", optimize=True)
    build_page(source).save(OUT / "page_frame.png", optimize=True)
    build_hinge(source).save(OUT / "hinge.png", optimize=True)
    for name, tab in build_nav_tabs().items():
        tab.save(OUT / name, optimize=True)
    for name in ("spine_leather.png", "page_frame.png", "hinge.png", "nav_tab_normal.png",
                 "nav_tab_active.png"):
        with Image.open(OUT / name) as image:
            print(name, image.size)


if __name__ == "__main__":
    main()
