"""Scatter cut-out plants onto a toroidal RGBA canvas -> tileable ground cover.

Plants are placed with wrap-around, so the result tiles seamlessly without any
blending. Alpha is real: gaps between plants are fully transparent, so the
terrain shows through and cover density is decided by the texture itself.
"""
from __future__ import annotations

import numpy as np
from PIL import Image

import cutout


def _premult(rgba: np.ndarray) -> np.ndarray:
    out = rgba.copy()
    out[..., :3] *= out[..., 3:4]
    return out


def _transform(sprite: np.ndarray, size: int, angle: float, flip: bool) -> np.ndarray:
    """Rotate/scale a straight-alpha sprite (RGB already alpha-bled), then
    premultiply. PIL premultiplies internally while resizing RGBA, so feeding
    it straight data is correct; rotation is safe because the transparent
    texels carry the nearest object colour instead of the key colour."""
    if flip:
        sprite = sprite[:, ::-1]
    im = Image.fromarray((np.clip(sprite, 0, 1) * 255).astype(np.uint8), "RGBA")
    im = im.resize((size, size), Image.Resampling.LANCZOS)
    im = im.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    return _premult(np.asarray(im, dtype=np.float32) / 255.0)


def _blit_wrapped(canvas: np.ndarray, spr: np.ndarray, cx: int, cy: int) -> None:
    n = canvas.shape[0]
    h, w = spr.shape[:2]
    ys = (np.arange(h) + cy - h // 2) % n
    xs = (np.arange(w) + cx - w // 2) % n
    dst = canvas[np.ix_(ys, xs)]
    canvas[np.ix_(ys, xs)] = spr + dst * (1.0 - spr[..., 3:4])


def scatter(sprites: list[np.ndarray], tile: int = 512, diameter: int = 120,
            spacing: float = 0.62, scale_jitter: float = 0.22,
            target_cover: float = 0.62, seed: int = 1) -> np.ndarray:
    """Return float32 tile x tile x 4, straight (un-premultiplied) alpha."""
    rng = np.random.default_rng(seed)
    pre = [cutout.crop_square(s, pad=0.0) for s in sprites]
    canvas = np.zeros((tile, tile, 4), dtype=np.float32)
    centers: list[tuple[float, float, float]] = []
    tries = 0
    while tries < 6000:
        tries += 1
        k = 1.0 + rng.uniform(-scale_jitter, scale_jitter)
        d = diameter * k
        cx, cy = rng.uniform(0, tile, 2)
        ok = True
        for ox, oy, od in centers:
            dx = abs(cx - ox); dx = min(dx, tile - dx)
            dy = abs(cy - oy); dy = min(dy, tile - dy)
            if np.hypot(dx, dy) < (d + od) * 0.5 * spacing:
                ok = False
                break
        if not ok:
            continue
        centers.append((cx, cy, d))
        spr = _transform(pre[int(rng.integers(len(pre)))], int(d),
                         float(rng.uniform(0, 360)), bool(rng.integers(2)))
        _blit_wrapped(canvas, spr, int(cx), int(cy))
        if (canvas[..., 3] > 0.5).mean() >= target_cover:
            break
    a = canvas[..., 3:4]
    rgb = np.where(a > 1e-4, canvas[..., :3] / np.maximum(a, 1e-4), 0.0)
    out = np.clip(np.concatenate([rgb, a], axis=2), 0, 1)
    return cutout.alpha_bleed(out)


def coverage(tile_rgba: np.ndarray) -> float:
    return float((tile_rgba[..., 3] > 0.5).mean())


def wrap_alpha_error(tile_rgba: np.ndarray) -> float:
    """Max alpha step across the wrap edge; ~inner-edge steps means seamless."""
    a = tile_rgba[..., 3]
    wrap = max(np.abs(a[:, 0] - a[:, -1]).max(), np.abs(a[0] - a[-1]).max())
    inner = max(np.abs(a[:, 1:] - a[:, :-1]).max(), np.abs(a[1:] - a[:-1]).max())
    return float(wrap / max(inner, 1e-6))
