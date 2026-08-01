# [terrain-material-tiles] GPT-image-2 风格化源图 -> 游戏自定义打包格式：
#   R = 亮度细节（均值归一化到 0.5，shader: 1+(r-0.5)*2*albedo_strength）
#   G/B = 由亮度导出的切线空间法线 XY（shader: (gb*2-1)*normal_strength）
#   A = 绝对粗糙度（shader: mix(biome_rough, a, 0.35)），按材质族给基底 + 亮度微变
# 另做四方连续化：半幅滚动副本 + 边缘平滑权重混合，保证 repeat 采样无接缝。
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

FAMILIES = {
    "organic": 0.78,
    "dry_sand": 0.72,
    "rock": 0.60,
    "snow_wet": 0.42,
}
TARGET = 1024
NORMAL_SCALE = 1.6
TARGET_STD = 0.13


def smooth_ramp(t: np.ndarray) -> np.ndarray:
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def make_tileable(img: np.ndarray, border_frac: float = 0.125) -> np.ndarray:
    h, w = img.shape[:2]
    rolled = np.roll(np.roll(img, h // 2, axis=0), w // 2, axis=1)
    ramp_x = smooth_ramp(np.minimum(np.arange(w), w - 1 - np.arange(w)) / (w * border_frac))
    ramp_y = smooth_ramp(np.minimum(np.arange(h), h - 1 - np.arange(h)) / (h * border_frac))
    weight = (ramp_y[:, None] * ramp_x[None, :])[..., None]
    return img * weight + rolled * (1.0 - weight)


def process(src: Path, dst: Path, rough_base: float) -> None:
    im = Image.open(src).convert("RGB")
    if im.size != (TARGET, TARGET):
        im = im.resize((TARGET, TARGET), Image.LANCZOS)
    arr = np.asarray(im, dtype=np.float64) / 255.0

    arr = make_tileable(arr)

    luma = (0.2126 * arr[..., 0] + 0.7152 * arr[..., 1] + 0.0722 * arr[..., 2])
    std = max(float(luma.std()), 1e-4)
    luma = np.clip((luma - luma.mean()) * (TARGET_STD / std) + 0.5, 0.02, 0.98)

    height_img = Image.fromarray((luma * 255.0).astype(np.uint8), "L")
    height_img = height_img.filter(ImageFilter.GaussianBlur(1.5))
    height = np.asarray(height_img, dtype=np.float64) / 255.0

    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    nx = np.clip(-dx * NORMAL_SCALE * 8.0, -1.0, 1.0)
    ny = np.clip(-dy * NORMAL_SCALE * 8.0, -1.0, 1.0)

    rough = np.clip(rough_base + (luma - 0.5) * 0.15, 0.0, 1.0)

    out = np.stack([
        luma,
        nx * 0.5 + 0.5,
        ny * 0.5 + 0.5,
        rough,
    ], axis=-1)
    Image.fromarray((out * 255.0).astype(np.uint8), "RGBA").save(dst)
    print(f"packed {src.name} -> {dst.name} rough_base={rough_base}")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: pack_terrain_materials.py <src_dir> <dst_dir>")
        return 1
    src_dir, dst_dir = Path(sys.argv[1]), Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)
    for name, rough in FAMILIES.items():
        src = src_dir / f"{name}.png"
        if not src.exists():
            print(f"MISSING {src}")
            return 1
        process(src, dst_dir / f"{name}.png", rough)
    return 0


if __name__ == "__main__":
    sys.exit(main())
