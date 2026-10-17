"""Cut a sprite out of a flat grey background and prepare it for atlasing."""
from __future__ import annotations

import numpy as np
from scipy import ndimage


def _smoothstep(a: float, b: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - a) / max(b - a, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def estimate_background(img: np.ndarray, patch: int = 24) -> np.ndarray:
    """Median colour of the four corner patches. img: float32 HxWx3 in 0..1."""
    corners = [img[:patch, :patch], img[:patch, -patch:],
               img[-patch:, :patch], img[-patch:, -patch:]]
    return np.median(np.concatenate([c.reshape(-1, 3) for c in corners]), axis=0)


def cut_out(img: np.ndarray, lo: float = 0.045, hi: float = 0.11) -> np.ndarray:
    """Return float32 HxWx4 (RGB un-premultiplied, A soft matte).

    Alpha comes from colour distance to the background. Only the largest
    connected blob is kept and interior holes are filled, so pale patches on
    the animal that happen to match the grey do not punch through the body.
    """
    bg = estimate_background(img)
    dist = np.sqrt(((img - bg) ** 2).sum(axis=2))
    soft = _smoothstep(lo, hi, dist)
    hard = soft > 0.5
    hard = ndimage.binary_opening(hard, iterations=2)
    labels, n = ndimage.label(hard)
    if n == 0:
        raise ValueError("cut_out: nothing found against the background")
    sizes = ndimage.sum(hard, labels, index=np.arange(1, n + 1))
    keep = labels == (int(np.argmax(sizes)) + 1)
    filled = ndimage.binary_fill_holes(keep)
    # Soft edge: the colour-distance matte near the contour, solid inside.
    inner = ndimage.binary_erosion(filled, iterations=3)
    region = ndimage.binary_dilation(filled, iterations=2)
    alpha = np.where(inner, 1.0, np.where(region, soft, 0.0)).astype(np.float32)
    alpha = ndimage.gaussian_filter(alpha, 0.8)
    alpha = np.clip(alpha * region, 0.0, 1.0)
    return np.dstack([img, alpha]).astype(np.float32)


def cut_out_many(img: np.ndarray, lo: float = 0.12, hi: float = 0.45,
                 min_area: int = 4000, group_px: int = 7) -> list[np.ndarray]:
    """Split a sheet of isolated objects on a flat key colour into RGBA crops.

    Colour is un-mixed against the key colour (c = (obs - (1-a)*bg) / a), so
    thin whiskers and soft edges do not keep a magenta fringe.
    Returns tight float32 HxWx4 crops, RGB un-premultiplied.
    """
    bg = estimate_background(img)
    dist = np.sqrt(((img - bg) ** 2).sum(axis=2))
    a = _smoothstep(lo, hi, dist).astype(np.float32)
    # Group strokes of the same object (leaves, whiskers) into one blob.
    grouped = ndimage.binary_dilation(a > 0.5, iterations=group_px)
    labels, n = ndimage.label(grouped)
    # Thin ears/whiskers are all edge pixels, so linear un-mixing leaves a
    # magenta cast. Take colour from the nearest fully-opaque ("core") pixel
    # instead; only alpha keeps the soft silhouette.
    # "Magenta-ness": R and B high with G low. Pure gold / green / brown are
    # strongly negative; a gold+key mix is positive. Contaminated pixels are
    # neither a colour source nor allowed to stay opaque.
    key_dir = bg - bg.mean()
    mag = np.minimum(img[..., 0], img[..., 2]) - img[..., 1] if key_dir[1] < 0 else dist * 0
    a = a * (1.0 - _smoothstep(-0.05, 0.20, mag)).astype(np.float32)
    core = (dist >= hi) & (mag < -0.10)
    _, (iy, ix) = ndimage.distance_transform_edt(~core, return_indices=True)
    rgb = img[iy, ix]
    full = np.dstack([rgb, a]).astype(np.float32)
    out = []
    for i, sl in enumerate(ndimage.find_objects(labels), start=1):
        if sl is None:
            continue
        mask = labels[sl] == i
        if (a[sl] > 0.5)[mask].sum() < min_area:
            continue
        crop = full[sl].copy()
        crop[..., 3] *= mask
        out.append(alpha_bleed(crop))
    return out


def crop_square(rgba: np.ndarray, pad: float = 0.06) -> np.ndarray:
    """Crop to the alpha bounding box, then centre it in a transparent square."""
    ys, xs = np.nonzero(rgba[..., 3] > 0.02)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    crop = rgba[y0:y1, x0:x1]
    h, w = crop.shape[:2]
    side = int(round(max(h, w) * (1.0 + 2.0 * pad)))
    out = np.zeros((side, side, 4), dtype=np.float32)
    oy, ox = (side - h) // 2, (side - w) // 2
    out[oy:oy + h, ox:ox + w] = crop
    return out


def alpha_bleed(rgba: np.ndarray) -> np.ndarray:
    """Copy the nearest opaque colour into fully transparent texels.

    Without this, bilinear filtering and mip generation pull the grey capture
    background into the sprite edge as a visible halo.
    """
    solid = rgba[..., 3] > 0.02
    _, (iy, ix) = ndimage.distance_transform_edt(~solid, return_indices=True)
    out = rgba.copy()
    out[..., :3] = rgba[iy, ix, :3]
    return out
