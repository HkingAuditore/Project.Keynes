"""Make a square RGB texture tile seamlessly by offset cross-blending.

pack_tiles._periodicize only matches border texels and a one-texel gradient,
which is fine for noisy terrain but leaves visible seams on clumped
vegetation. Here the image is rolled by half a tile so the original seams move
to the centre cross, then the original is blended back in with a weight that is
0 on the borders and 1 in the middle. Border pixels therefore come from the
rolled copy (continuous across the wrap) and centre pixels from the original
(continuous in the middle), so no seam survives on either side.
"""
from __future__ import annotations

import numpy as np


def _ramp(n: int, width: float) -> np.ndarray:
    """0 at both ends, 1 in the middle, smoothstep over `width` of the length."""
    t = (np.arange(n, dtype=np.float32) + 0.5) / n
    d = np.minimum(t, 1.0 - t) / max(width, 1e-4)
    d = np.clip(d, 0.0, 1.0)
    return d * d * (3.0 - 2.0 * d)


def make_seamless(img: np.ndarray, blend_width: float = 0.28) -> np.ndarray:
    """img: float32 HxWxC in 0..1. Returns an array of the same shape."""
    h, w = img.shape[:2]
    rolled = np.roll(img, (h // 2, w // 2), axis=(0, 1))
    wy = _ramp(h, blend_width)[:, None]
    wx = _ramp(w, blend_width)[None, :]
    weight = (wx * wy)[..., None]
    return img * weight + rolled * (1.0 - weight)


def wrap_seam_error(img: np.ndarray) -> float:
    """Mean abs colour step across the wrap, relative to the mean step inside.

    ~1.0 means the wrap edge is statistically indistinguishable from any other
    pixel boundary; much larger than 1 means a visible seam.
    """
    h, w = img.shape[:2]
    wrap = (np.abs(img[:, 0] - img[:, -1]).mean()
            + np.abs(img[0] - img[-1]).mean()) * 0.5
    inner = (np.abs(img[:, 1:] - img[:, :-1]).mean()
             + np.abs(img[1:] - img[:-1]).mean()) * 0.5
    return float(wrap / max(inner, 1e-6))


def tile_preview(img: np.ndarray, reps: int = 3) -> np.ndarray:
    return np.tile(img, (reps, reps, 1))
