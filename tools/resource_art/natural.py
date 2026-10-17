"""Natural-looking vegetation cover: asymmetric fragments + clustered density.

Differences from scatter.py (which stamps whole symmetric rosettes):
  * sprites are cut into random angular wedges, so every stamp is lopsided;
  * density comes from a toroidal low-frequency noise field, so plants form
    colonies with clearings instead of an even carpet. A lower abundance only
    keeps the densest colonies, so sparse is a subset of dense (this is the
    same rule the shader will use at runtime);
  * size, tint and straw-yellowing vary per plant; stressed plants sit at the
    colony edge;
  * a faint blurred under-mat ties the plants together like trampled stalks.
"""
from __future__ import annotations

import numpy as np
from scipy import ndimage

import cutout
import scatter


def density_field(tile: int, seed: int) -> np.ndarray:
    """Periodic 0..1 field, uniform histogram, patches ~tile/5 across."""
    rng = np.random.default_rng(seed)
    f = np.zeros((tile, tile), dtype=np.float32)
    for sigma, w in ((tile / 9.0, 1.0), (tile / 22.0, 0.55), (tile / 60.0, 0.2)):
        n = ndimage.gaussian_filter(rng.standard_normal((tile, tile)).astype(np.float32),
                                    sigma, mode="wrap")
        f += w * n / max(float(n.std()), 1e-6)
    rank = f.ravel().argsort().argsort().astype(np.float32)
    return (rank / (rank.size - 1)).reshape(tile, tile)


def wedge(sprite: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Keep a random angular slice of a square RGBA sprite (pivot = centre)."""
    h, w = sprite.shape[:2]
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    ang = np.arctan2(y - h / 2, x - w / 2)
    span = np.deg2rad(rng.uniform(70, 190))
    mid = rng.uniform(-np.pi, np.pi)
    delta = np.abs((ang - mid + np.pi) % (2 * np.pi) - np.pi)
    feather = np.deg2rad(10.0)
    k = np.clip((span / 2 - delta) / feather + 0.5, 0.0, 1.0)
    # Keep the hub intact so each fragment still reads as a plant base.
    r = np.hypot(x - w / 2, y - h / 2) / (min(h, w) / 2)
    k = np.maximum(k, np.clip(1.0 - r / 0.16, 0.0, 1.0))
    out = sprite.copy()
    out[..., 3] *= k
    return out


STRAW = np.array([0.78, 0.70, 0.38], dtype=np.float32)


def natural_cover(sprites: list[np.ndarray], tile: int = 512, base_diameter: int = 120,
                  abundance: float = 0.5, field_seed: int = 11, seed: int = 1,
                  candidates: int = 3500) -> np.ndarray:
    rng = np.random.default_rng(seed)
    field = density_field(tile, field_seed)
    base = [cutout.crop_square(s, pad=0.0) for s in sprites]
    thresh = 1.0 - abundance
    placed: list[tuple[float, float, float, int, float]] = []
    pts = rng.uniform(0, tile, (candidates, 2))
    for cx, cy in pts:
        dd = float(field[int(cy), int(cx)])
        p = np.clip((dd - thresh) / 0.22, 0.0, 1.0) ** 0.8
        if rng.random() >= p:
            continue
        k = rng.uniform(0.5, 1.15) * (0.82 + 0.36 * dd)
        d = base_diameter * k
        if placed:
            arr = np.asarray(placed)
            dx = np.abs(arr[:, 0] - cx); dx = np.minimum(dx, tile - dx)
            dy = np.abs(arr[:, 1] - cy); dy = np.minimum(dy, tile - dy)
            if np.any(np.hypot(dx, dy) < (d + arr[:, 2]) * 0.5 * 0.28):
                continue
        placed.append((cx, cy, d, int(rng.integers(len(base))), dd))
    canvas = np.zeros((tile, tile, 4), dtype=np.float32)
    # Upright plants: whole sprite (no wedge), tilt only a few degrees, anchored
    # at the base and painted back-to-front (small y first) so nearer plants
    # overlap farther ones, like a field seen from the camera.
    for cx, cy, d, si, dd in sorted(placed, key=lambda t: t[1]):
        frag = base[si].copy()
        stress = float(np.clip((0.75 - dd) / 0.75, 0, 1)) * rng.uniform(0.0, 0.45)
        tint = rng.uniform(0.86, 1.08, 3).astype(np.float32)
        tint = tint * np.array([1.0, 1.0, rng.uniform(0.92, 1.0)], dtype=np.float32)
        frag[..., :3] = np.clip(
            (frag[..., :3] * (1 - stress) + STRAW * stress) * tint, 0, 1)
        spr = scatter._transform(frag, max(8, int(d)), float(rng.normal(0.0, 5.0)),
                                 bool(rng.integers(2)))
        # Sprite centre sits half a height above the base point.
        scatter._blit_wrapped(canvas, spr, int(cx), int(cy - spr.shape[0] * 0.40))
    # Under-mat: blurred alpha tinted like dead stalks, below the plants.
    a = canvas[..., 3]
    mat_a = np.clip(ndimage.gaussian_filter(a, 9, mode="wrap") * 0.9, 0, 0.55)
    mat_rgb = np.array([0.30, 0.31, 0.16], dtype=np.float32)
    pa = canvas[..., 3:4]
    prgb = canvas[..., :3]  # premultiplied
    out_a = pa + mat_a[..., None] * (1 - pa)
    out_prgb = prgb + mat_rgb * (mat_a[..., None] * (1 - pa))
    rgb = np.where(out_a > 1e-4, out_prgb / np.maximum(out_a, 1e-4), 0.0)
    out = np.clip(np.concatenate([rgb, out_a], axis=2), 0, 1)
    return cutout.alpha_bleed(out)
