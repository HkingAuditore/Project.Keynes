#!/usr/bin/env python3
"""Pack four tileable terrain material sources into RGBA8 maps.

The source directory must contain one RGB/RGBA image per material family:
``organic.png``, ``dry_sand.png``, ``rock.png`` and ``snow_wet.png``.
The generated PNG stores albedo variation in R, tangent-space normal XY in
G/B, and roughness in A.  Files are staged in a temporary directory and are
published only after optional periodic-edge validation succeeds.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image


MATERIAL_NAMES = ("organic", "dry_sand", "rock", "snow_wet")
MAX_EDGE_ERROR = 2
MAX_GRADIENT_ERROR = 4


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path,
                        help="directory containing the four source images")
    parser.add_argument("--output", required=True, type=Path,
                        help="directory receiving the final PNG files")
    parser.add_argument("--size", required=True, type=int,
                        help="square output size, normally 1024 or 512")
    parser.add_argument("--verify", action="store_true",
                        help="fail when periodic edge or format checks do not pass")
    return parser.parse_args()


def _source_path(input_dir: Path, name: str) -> Path | None:
    for suffix in (".png", ".jpg", ".jpeg", ".webp"):
        for stem in (name, name + "_source", name + "_albedo"):
            candidate = input_dir / (stem + suffix)
            if candidate.is_file():
                return candidate
    return None


def _load_rgb(path: Path, size: int) -> np.ndarray:
    with Image.open(path) as image:
        image = image.convert("RGB")
        if image.size != (size, size):
            image = image.resize((size, size), Image.Resampling.LANCZOS)
        return np.asarray(image, dtype=np.float32) / 255.0


def _periodicize_axis(data: np.ndarray, axis: int) -> np.ndarray:
    """Match the border texels and first derivative across one axis."""
    out = data.copy()
    if axis == 1:
        edge_a = out[:, 0, :].copy()
        edge_b = out[:, -1, :].copy()
        edge = (edge_a + edge_b) * 0.5
        gradient = ((out[:, 1, :] - edge) + (edge - out[:, -2, :])) * 0.5
        out[:, 0, :] = edge
        out[:, -1, :] = edge
        out[:, 1, :] = edge + gradient
        out[:, -2, :] = edge - gradient
    else:
        edge_a = out[0, :, :].copy()
        edge_b = out[-1, :, :].copy()
        edge = (edge_a + edge_b) * 0.5
        gradient = ((out[1, :, :] - edge) + (edge - out[-2, :, :])) * 0.5
        out[0, :, :] = edge
        out[-1, :, :] = edge
        out[1, :, :] = edge + gradient
        out[-2, :, :] = edge - gradient
    return out


def _periodicize(data: np.ndarray) -> np.ndarray:
    # Repeating both axes twice keeps corner edits and the two one-texel
    # gradients consistent after the orthogonal axis is corrected.
    out = data
    for _ in range(2):
        out = _periodicize_axis(out, 1)
        out = _periodicize_axis(out, 0)
    return out


def _pack_source(source: np.ndarray) -> np.ndarray:
    source = _periodicize(source)
    # Luminance is the neutral scalar supplied to the shader's albedo
    # modulation. Keeping the source colour out of G/B makes the packed
    # contract independent of the author's palette.
    height = np.clip(
        source[..., 0] * 0.2126
        + source[..., 1] * 0.7152
        + source[..., 2] * 0.0722,
        0.0,
        1.0,
    )
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    normal_scale = 2.25
    nx = np.clip(-dx * normal_scale, -0.95, 0.95)
    ny = np.clip(-dy * normal_scale, -0.95, 0.95)
    # A neutral, non-metallic terrain surface is generally rough.  The
    # luminance term gives snow/ice a slightly smoother response without
    # adding directional information to the asset.
    roughness = np.clip(0.82 - height * 0.30, 0.18, 0.92)
    packed = np.empty((*height.shape, 4), dtype=np.uint8)
    packed[..., 0] = np.rint(height * 255.0).astype(np.uint8)
    packed[..., 1] = np.rint((nx * 0.5 + 0.5) * 255.0).astype(np.uint8)
    packed[..., 2] = np.rint((ny * 0.5 + 0.5) * 255.0).astype(np.uint8)
    packed[..., 3] = np.rint(roughness * 255.0).astype(np.uint8)
    return packed


def _edge_metrics(data: np.ndarray) -> tuple[int, int]:
    horizontal = np.abs(data[:, 0, :].astype(np.int16)
                        - data[:, -1, :].astype(np.int16))
    vertical = np.abs(data[0, :, :].astype(np.int16)
                      - data[-1, :, :].astype(np.int16))
    edge_error = int(max(horizontal.max(initial=0), vertical.max(initial=0)))

    horizontal_gradient = np.abs(
        (data[:, 1, :].astype(np.int16) - data[:, 0, :].astype(np.int16))
        - (data[:, -1, :].astype(np.int16) - data[:, -2, :].astype(np.int16))
    )
    vertical_gradient = np.abs(
        (data[1, :, :].astype(np.int16) - data[0, :, :].astype(np.int16))
        - (data[-1, :, :].astype(np.int16) - data[-2, :, :].astype(np.int16))
    )
    gradient_error = int(max(
        horizontal_gradient.max(initial=0), vertical_gradient.max(initial=0)
    ))
    return edge_error, gradient_error


def _validate(data: np.ndarray, size: int, label: str) -> list[str]:
    failures: list[str] = []
    if data.shape != (size, size, 4):
        failures.append(f"{label}: expected {size}x{size} RGBA, got {data.shape}")
        return failures
    edge_error, gradient_error = _edge_metrics(data)
    if edge_error > MAX_EDGE_ERROR:
        failures.append(f"{label}: edge error {edge_error} > {MAX_EDGE_ERROR}")
    if gradient_error > MAX_GRADIENT_ERROR:
        failures.append(
            f"{label}: gradient error {gradient_error} > {MAX_GRADIENT_ERROR}"
        )
    return failures


def main() -> int:
    args = _parse_args()
    if args.size < 16 or args.size > 4096:
        print("--size must be between 16 and 4096", file=sys.stderr)
        return 2
    if not args.input.is_dir():
        print(f"input directory does not exist: {args.input}", file=sys.stderr)
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temp_dir = Path(tempfile.mkdtemp(prefix="terrain_materials.",
                                      dir=str(args.output.parent)))
    staged: list[tuple[Path, Path]] = []
    failures: list[str] = []
    try:
        for name in MATERIAL_NAMES:
            source_path = _source_path(args.input, name)
            if source_path is None:
                failures.append(f"{name}: missing source image")
                continue
            try:
                packed = _pack_source(_load_rgb(source_path, args.size))
            except Exception as exc:  # pragma: no cover - diagnostic path
                failures.append(f"{name}: {exc}")
                continue
            image = Image.fromarray(packed, mode="RGBA")
            staged_path = temp_dir / f"{name}.png"
            image.save(staged_path, format="PNG", optimize=True)
            staged.append((staged_path, args.output / f"{name}.png"))
            if args.verify:
                failures.extend(_validate(packed, args.size, name))

        if failures:
            for failure in failures:
                print(f"[FAIL] {failure}", file=sys.stderr)
            return 2

        args.output.mkdir(parents=True, exist_ok=True)
        for staged_path, final_path in staged:
            os.replace(staged_path, final_path)
        print(f"packed {len(staged)} tileable terrain materials at {args.size}x{args.size}")
        return 0
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
