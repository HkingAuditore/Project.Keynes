"""Bake seamlessly tileable forest canopy Texture2DArray strips from crown art.

Run with Python, Pillow, NumPy and SciPy:
    python Project/project-keynes/tools/resource_art/build_forest_canopy_tiles.py

Outputs two 512x1536 RGBA vertical strips (3 stacked 512x512 layers):
  Layer 0: broadleaf
  Layer 1: conifer
  Layer 2: palm

- forest_canopy_albedo_tiles.png:
    RGB = crown-tone normalised foliage colour (periodic alpha-bled for mipmaps)
    A   = canopy coverage [0, 1]
- forest_canopy_aux_tiles.png:
    RG  = canopy normal XY encoded in [0, 1] (rotated per crown)
    B   = upper visible canopy height [0, 1]
    A   = inter-crown + intra-crown AO [0, 1]
"""
from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ART = Path(__file__).resolve().parents[2] / "assets" / "textures" / "resource_art"
SEED = 0x51F02E57
TILE_SIZE = 512
SOURCE_CELL = 256
SOURCE_COLS = 4
SOURCE_ROWS = 2

# (name, source_layer, sprite_indices, min_diam, max_diam, spacing_ratio, target_count)
# Each single tile holds crisp, well-separated crowns (~50-60% coverage) so the
# shader can stack 1 layer at sparse margins, 2 layers in mid-forest, and 3
# layers in dense cores — producing sharp crown silhouettes with genuine density
# gradients instead of a flat blurry mask.
FAMILIES = (
    ("broadleaf", 0, tuple(range(8)), 44.0, 74.0, 0.72, 92),
    ("conifer", 1, tuple(range(8)), 36.0, 62.0, 0.70, 120),
    ("palm", 2, tuple(range(8)), 42.0, 68.0, 0.76, 85),
)


def load_strip(name: str) -> np.ndarray:
    path = ART / name
    with Image.open(path) as image:
        if image.mode != "RGBA":
            image = image.convert("RGBA")
        arr = np.asarray(image, dtype=np.float32) / 255.0
    expected_w = SOURCE_COLS * SOURCE_CELL
    if arr.shape[1] != expected_w or arr.shape[0] < 3 * SOURCE_ROWS * SOURCE_CELL:
        raise ValueError(f"{name} has unexpected shape {arr.shape}")
    return arr


def extract_crowns(
    albedo: np.ndarray, aux: np.ndarray, layer: int, sprites: tuple[int, ...]
) -> list[np.ndarray]:
    crowns: list[np.ndarray] = []
    for sprite in sprites:
        row, col = divmod(sprite, SOURCE_COLS)
        y = (layer * SOURCE_ROWS + row) * SOURCE_CELL
        x = col * SOURCE_CELL
        ys = slice(y, y + SOURCE_CELL)
        xs = slice(x, x + SOURCE_CELL)
        alpha = albedo[ys, xs, 3:4]
        if not (alpha > 0.5).any():
            raise ValueError(f"Empty crown at source layer {layer}, sprite {sprite}")
        normal_xy = aux[ys, xs, :2] * 2.0 - 1.0
        packed = np.concatenate((alpha, albedo[ys, xs, :3], normal_xy, aux[ys, xs, 2:]), axis=2)
        packed[..., 1:] *= alpha
        crowns.append(packed)
    return crowns


def transform_crown(source: np.ndarray, diameter: float, angle_deg: float) -> np.ndarray:
    mask_img = Image.fromarray(source[..., 0]).rotate(angle_deg, Image.Resampling.BICUBIC, expand=True)
    mask_arr = np.asarray(mask_img)
    ys, xs = np.nonzero(mask_arr > 4.0 / 255.0)
    if ys.size == 0:
        return np.zeros((1, 1, 8), dtype=np.float32)
    bounds = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
    width = bounds[2] - bounds[0]
    height = bounds[3] - bounds[1]
    scale = diameter / max(width, height)
    out_size = (max(1, round(width * scale)), max(1, round(height * scale)))

    channels = [np.asarray(mask_img.crop(bounds).resize(out_size, Image.Resampling.LANCZOS))]
    for ch in source.transpose(2, 0, 1)[1:]:
        rot = Image.fromarray(ch).rotate(angle_deg, Image.Resampling.BICUBIC, expand=True)
        channels.append(np.asarray(rot.crop(bounds).resize(out_size, Image.Resampling.LANCZOS)))
    crown = np.stack(channels, axis=2).astype(np.float32)
    alpha = crown[..., :1]
    np.clip(alpha, 0.0, 1.0, out=alpha)
    np.clip(crown[..., 1:4], 0.0, alpha, out=crown[..., 1:4])
    np.clip(crown[..., 6:], 0.0, alpha, out=crown[..., 6:])

    nx = crown[..., 4].copy()
    ny = crown[..., 5].copy()
    rad = math.radians(angle_deg)
    ca, sa = math.cos(rad), math.sin(rad)
    crown[..., 4] = ca * nx - sa * ny
    crown[..., 5] = sa * nx + ca * ny
    return crown


def periodic_dist_sq(x0: float, y0: float, x1: float, y1: float, period: float) -> float:
    dx = abs(x0 - x1)
    if dx > period * 0.5:
        dx = period - dx
    dy = abs(y0 - y1)
    if dy > period * 0.5:
        dy = period - dy
    return dx * dx + dy * dy


def periodic_poisson_crowns(
    rng: random.Random,
    min_diam: float,
    max_diam: float,
    spacing_ratio: float,
    target_count: int,
) -> list[tuple[float, float, float, float, tuple[float, float, float]]]:
    """Variable-radius periodic Poisson-disc placement on [0, TILE_SIZE)^2."""
    placed: list[tuple[float, float, float, float, tuple[float, float, float]]] = []
    max_attempts = target_count * 45
    for _ in range(max_attempts):
        if len(placed) >= target_count:
            break
        diam = rng.uniform(min_diam, max_diam)
        x = rng.uniform(0.0, float(TILE_SIZE))
        y = rng.uniform(0.0, float(TILE_SIZE))
        rad = diam * 0.5
        ok = True
        for px, py, pdiam, _, _ in placed:
            min_d = (rad + pdiam * 0.5) * spacing_ratio
            if periodic_dist_sq(x, y, px, py, float(TILE_SIZE)) < min_d * min_d:
                ok = False
                break
        if ok:
            angle = rng.uniform(0.0, 360.0)
            # Subtle per-crown brightness and warm/cool leaf variation for close-up readability.
            val = rng.uniform(0.86, 1.14)
            warm = rng.uniform(-0.04, 0.05)
            tint = (val * (1.0 + warm), val, val * (1.0 - warm * 0.6))
            placed.append((x, y, diam, angle, tint))
    # Sort smaller crowns first so larger/taller crowns naturally overtop smaller ones.
    placed.sort(key=lambda item: item[2])
    return placed


def periodic_bleed(rgb: np.ndarray, aux: np.ndarray, alpha: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Pad RGB/aux through transparent gaps on a 3x3 tiled domain to preserve tileability."""
    tiled_alpha = np.tile(alpha, (3, 3))
    tiled_rgb = np.tile(rgb, (3, 3, 1))
    tiled_aux = np.tile(aux, (3, 3, 1))
    solid = tiled_alpha >= 0.25
    if not solid.any():
        return rgb, aux
    distance, indices = ndimage.distance_transform_edt(~solid, return_indices=True)
    nearest = tuple(indices)
    filled_rgb = tiled_rgb.copy()
    filled_rgb[~solid] = tiled_rgb[nearest][~solid]

    neutral = np.array((0.5, 0.5, 0.0, 1.0), dtype=np.float32)
    weight = np.clip((18.0 - distance) / 14.0, 0.0, 1.0)[..., None]
    filled_aux = tiled_aux.copy()
    filled_aux[~solid] = (neutral + (tiled_aux[nearest] - neutral) * weight)[~solid]

    sl = slice(TILE_SIZE, TILE_SIZE * 2)
    return filled_rgb[sl, sl], filled_aux[sl, sl]


def bake_family_tile(
    sources: list[np.ndarray],
    min_diam: float,
    max_diam: float,
    spacing_ratio: float,
    target_count: int,
    seed: int,
) -> tuple[np.ndarray, np.ndarray]:
    rng = random.Random(seed)
    placements = periodic_poisson_crowns(rng, min_diam, max_diam, spacing_ratio, target_count)

    # Accumulate in premultiplied space:
    # 0: alpha, 1..3: rgb, 4..5: normal_xy, 6: height, 7: source_ao
    comp = np.zeros((TILE_SIZE, TILE_SIZE, 8), dtype=np.float32)
    top_height = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.float32)

    order = list(range(len(sources)))
    rng.shuffle(order)

    for idx, (cx, cy, diam, angle, tint) in enumerate(placements):
        src = sources[order[idx % len(order)]]
        sprite = transform_crown(src, diam, angle)
        sh, sw = sprite.shape[:2]
        if sh <= 0 or sw <= 0:
            continue
        sprite[..., 1] *= tint[0]
        sprite[..., 2] *= tint[1]
        sprite[..., 3] *= tint[2]
        # Scale crown height slightly with crown diameter so taller trees rise above understory.
        height_scale = 0.72 + 0.28 * ((diam - min_diam) / max(max_diam - min_diam, 1.0))
        sprite[..., 6] *= height_scale

        x0 = round(cx - sw * 0.5)
        y0 = round(cy - sh * 0.5)
        for ox in (-TILE_SIZE, 0, TILE_SIZE):
            lx = x0 + ox
            rx = lx + sw
            if rx <= 0 or lx >= TILE_SIZE:
                continue
            dst_x0 = max(0, lx)
            dst_x1 = min(TILE_SIZE, rx)
            src_x0 = dst_x0 - lx
            src_x1 = src_x0 + (dst_x1 - dst_x0)
            for oy in (-TILE_SIZE, 0, TILE_SIZE):
                ty = y0 + oy
                by = ty + sh
                if by <= 0 or ty >= TILE_SIZE:
                    continue
                dst_y0 = max(0, ty)
                dst_y1 = min(TILE_SIZE, by)
                src_y0 = dst_y0 - ty
                src_y1 = src_y0 + (dst_y1 - dst_y0)

                patch = sprite[src_y0:src_y1, src_x0:src_x1]
                a = patch[..., :1]
                reg = np.s_[dst_y0:dst_y1, dst_x0:dst_x1]
                comp[reg] *= 1.0 - a
                comp[reg] += patch
                # Upper visible canopy height
                p_h = patch[..., 6]
                top_height[reg] = np.maximum(top_height[reg] * (1.0 - a[..., 0] * 0.35), p_h)

    alpha = np.clip(comp[..., 0], 0.0, 1.0)
    inv_a = 1.0 / np.maximum(alpha, 1e-6)
    rgb = np.clip(comp[..., 1:4] * inv_a[..., None], 0.0, 1.0)
    nxy = np.clip(comp[..., 4:6] * inv_a[..., None], -1.0, 1.0)
    src_ao = np.clip(comp[..., 7] * inv_a, 0.0, 1.0)

    # Periodic inter-crown ambient occlusion from surrounding taller canopy:
    # push deep crevices dark (down to ~0.18) while keeping sunlit crown tops bright
    # so the canopy reads as volumetric 3D domes rather than a flat decal.
    height_smooth_small = ndimage.gaussian_filter(top_height, sigma=4.5, mode="wrap")
    height_smooth_wide = ndimage.gaussian_filter(top_height, sigma=14.0, mode="wrap")
    cavity_small = np.clip((height_smooth_small - top_height) * 3.2, 0.0, 0.58)
    cavity_wide = np.clip((height_smooth_wide - top_height) * 2.0, 0.0, 0.42)
    inter_ao = np.clip(1.0 - cavity_small - cavity_wide, 0.16, 1.0)
    ao = np.clip(src_ao * (0.30 + 0.70 * inter_ao), 0.15, 1.0)

    # Combine crisp sprite normal with macro canopy dome gradient for strong 3D relief.
    gy, gx = np.gradient(ndimage.gaussian_filter(top_height, sigma=1.8, mode="wrap"))
    macro_nx = np.clip(-gx * 4.8, -0.75, 0.75)
    macro_ny = np.clip(gy * 4.8, -0.75, 0.75)
    nx = nxy[..., 0] * 0.80 + macro_nx * 0.55
    ny = nxy[..., 1] * 0.80 + macro_ny * 0.55
    nz = np.sqrt(np.maximum(0.06, 1.0 - np.clip(nx * nx + ny * ny, 0.0, 0.94)))
    n_len = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx /= n_len
    ny /= n_len

    aux = np.stack(
        (nx * 0.5 + 0.5, ny * 0.5 + 0.5, np.clip(top_height, 0.0, 1.0), ao),
        axis=-1,
    ).astype(np.float32)

    rgb, aux = periodic_bleed(rgb, aux, alpha)
    albedo_out = np.concatenate((rgb, alpha[..., None]), axis=-1)
    return albedo_out, aux


def to_u8(arr: np.ndarray) -> np.ndarray:
    return np.clip(np.rint(arr * 255.0), 0, 255).astype(np.uint8)


def verify_tileable(name: str, albedo: np.ndarray, aux: np.ndarray) -> None:
    cov = float(albedo[..., 3].mean())
    edge_x = float(np.abs(albedo[:, 0, 3] - albedo[:, -1, 3]).mean())
    edge_y = float(np.abs(albedo[0, :, 3] - albedo[-1, :, 3]).mean())
    if cov < 0.30 or cov > 0.999:
        raise ValueError(f"{name}: unexpected mean coverage {cov:.3f}")
    if edge_x > 0.16 or edge_y > 0.16:
        raise ValueError(f"{name}: seam mismatch edge_x={edge_x:.3f}, edge_y={edge_y:.3f}")
    print(f"  {name:10s}: coverage={cov:.3f}, seam_dx={edge_x:.4f}, seam_dy={edge_y:.4f}, ao_mean={aux[..., 3].mean():.3f}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Bake tileable forest canopy textures.")
    parser.add_argument("--seed", type=int, default=SEED)
    args = parser.parse_args()

    src_albedo = load_strip("crown_atlas.png")
    src_aux = load_strip("crown_normal.png")

    albedo_layers: list[np.ndarray] = []
    aux_layers: list[np.ndarray] = []

    print(f"Baking {len(FAMILIES)} tileable {TILE_SIZE}x{TILE_SIZE} forest canopy layers...")
    for idx, (name, src_layer, sprites, min_d, max_d, spacing, count) in enumerate(FAMILIES):
        crowns = extract_crowns(src_albedo, src_aux, src_layer, sprites)
        albedo_tile, aux_tile = bake_family_tile(
            crowns, min_d, max_d, spacing, count, args.seed + idx * 1009
        )
        verify_tileable(name, albedo_tile, aux_tile)
        albedo_layers.append(albedo_tile)
        aux_layers.append(aux_tile)

    albedo_strip = np.concatenate(albedo_layers, axis=0)
    aux_strip = np.concatenate(aux_layers, axis=0)

    albedo_path = ART / "forest_canopy_albedo_tiles.png"
    aux_path = ART / "forest_canopy_aux_tiles.png"
    Image.fromarray(to_u8(albedo_strip), mode="RGBA").save(albedo_path, optimize=True)
    Image.fromarray(to_u8(aux_strip), mode="RGBA").save(aux_path, optimize=True)
    print(f"Saved:\n  {albedo_path}\n  {aux_path}")


if __name__ == "__main__":
    main()
