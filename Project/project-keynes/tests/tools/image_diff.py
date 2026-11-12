"""before/after 截图逐像素对比（桌面零回归验收）。

用法（在 Project/project-keynes 下）：
    <python> tests/tools/image_diff.py <before目录> <after目录> [after标签前缀]

before/ BEFORE_LABEL_  之后，文件名按 <label>_<page>_<W>x<H>.png 命名。本工具只把
"after" 目录里标签前缀匹配的图片，与 before 目录里的同名 page+尺寸 比较。
注意：主菜单背景是一张**每次运行都随机重生成**的装饰地图（papercut atlas），
所以跨进程截图天然有大量像素差；这里同时输出「差异包围盒」，用来判断差异是不是
集中在 UI 上（UI 区域有差异才是回归）。
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image


def load_pairs(before_dir: Path, after_dir: Path, after_label: str) -> list[tuple[str, Path, Path]]:
    pairs: list[tuple[str, Path, Path]] = []
    prefix = f"{after_label}_"
    for after in sorted(after_dir.glob(f"{prefix}*.png")):
        key = after.stem[len(prefix):]
        candidate = before_dir / f"before_{key}.png"
        if candidate.exists():
            pairs.append((key, candidate, after))
    return pairs


def diff(a: Path, b: Path, region=None) -> dict:
    ia = np.asarray(Image.open(a).convert("RGB"), dtype=np.int16)
    ib = np.asarray(Image.open(b).convert("RGB"), dtype=np.int16)
    if ia.shape != ib.shape:
        return {"shape_mismatch": (ia.shape, ib.shape)}
    delta = np.abs(ia - ib)
    mask = delta.max(axis=2) > 2  # 容差 2/255，滤掉浮点/抖动噪声
    if region is not None:
        x, y, w, h = region
        ia = ia[y:y + h, x:x + w]
        ib = ib[y:y + h, x:x + w]
        delta = np.abs(ia - ib)
        mask = delta.max(axis=2) > 2
    changed = int(mask.sum())
    total = int(mask.size)
    bbox = None
    if changed:
        ys, xs = np.nonzero(mask)
        bbox = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))
    return {
        "changed": changed,
        "total": total,
        "ratio": changed / total,
        "max_delta": int(delta.max()),
        "bbox": bbox,
        "shape": ia.shape,
    }


def main() -> int:
    before_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "test_output/mobile_ui/before")
    after_dir = Path(sys.argv[2] if len(sys.argv) > 2 else "test_output/mobile_ui/after")
    after_label = sys.argv[3] if len(sys.argv) > 3 else "after_desktop"
    region = None
    if len(sys.argv) > 4:
        region = tuple(int(v) for v in sys.argv[4].split(","))  # x,y,w,h
    pairs = load_pairs(before_dir, after_dir, after_label)
    if not pairs:
        print(f"没有可对比的图片：{before_dir} vs {after_dir}")
        return 2
    worst = 0.0
    for key, a, b in pairs:
        result = diff(a, b, region)
        if "shape_mismatch" in result:
            print(f"{key:34s} 尺寸不同 {result['shape_mismatch']}")
            worst = 1.0
            continue
        worst = max(worst, result["ratio"] * 100)
        print(f"{key:34s} {result['shape'][1]}x{result['shape'][0]} "
              f"diff={result['changed']:8d}/{result['total']} "
              f"({result['ratio'] * 100:6.3f}%) maxΔ={result['max_delta']:3d} bbox={result['bbox']}")
    print(f"\n最大差异占比：{worst:.3f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
