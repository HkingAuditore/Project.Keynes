#!/usr/bin/env python3
"""Pack a generated militia action sheet into a review GIF.

The source is a single 4x2 RGBA action sheet produced by the image generator.
This utility only cleans low-alpha generator spill, slices the fixed cells,
and composites them on the project's warm paper review matte. It does not
redraw or retime the unit artwork.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image


GRID_COLUMNS = 4
GRID_ROWS = 2
FRAME_DURATION_MS = 125
ALPHA_CUTOFF = 32
REVIEW_MATTE = (233, 218, 187, 255)


def _clean_alpha(image: Image.Image) -> Image.Image:
    image = image.convert("RGBA")
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            if a < ALPHA_CUTOFF:
                pixels[x, y] = (0, 0, 0, 0)
            elif a < 255:
                pixels[x, y] = (r, g, b, min(255, a * 2))
    return image


def _cell_bounds(index: int, width: int, height: int) -> tuple[int, int, int, int]:
    column = index % GRID_COLUMNS
    row = index // GRID_COLUMNS
    left = round(column * width / GRID_COLUMNS)
    right = round((column + 1) * width / GRID_COLUMNS)
    top = round(row * height / GRID_ROWS)
    bottom = round((row + 1) * height / GRID_ROWS)
    return left, top, right, bottom


def _load_frames(source: Path, frame_size: int) -> list[Image.Image]:
    sheet = _clean_alpha(Image.open(source))
    if sheet.width < GRID_COLUMNS or sheet.height < GRID_ROWS:
        raise ValueError(f"source sheet is too small: {sheet.size}")

    frames: list[Image.Image] = []
    for index in range(GRID_COLUMNS * GRID_ROWS):
        cell = sheet.crop(_cell_bounds(index, sheet.width, sheet.height))
        cell = cell.resize((frame_size, frame_size), Image.Resampling.LANCZOS)
        matte = Image.new("RGBA", cell.size, REVIEW_MATTE)
        matte.alpha_composite(cell)
        frames.append(matte.convert("RGB"))
    return frames


def _save_gif(frames: list[Image.Image], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        output,
        format="GIF",
        save_all=True,
        append_images=frames[1:],
        duration=FRAME_DURATION_MS,
        loop=0,
        disposal=2,
        optimize=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--clean-sheet", type=Path)
    parser.add_argument("--frame-size", type=int, default=256)
    args = parser.parse_args()

    source = args.source.resolve()
    cleaned = _clean_alpha(Image.open(source))
    if args.clean_sheet:
        args.clean_sheet.parent.mkdir(parents=True, exist_ok=True)
        cleaned.save(args.clean_sheet, format="PNG")
    frames = _load_frames(source, args.frame_size)
    _save_gif(frames, args.output)
    report = args.output.with_suffix(".json")
    report.write_text(
        json.dumps(
            {
                "source": str(source),
                "grid": [GRID_COLUMNS, GRID_ROWS],
                "frames": len(frames),
                "frame_size": args.frame_size,
                "duration_ms": FRAME_DURATION_MS,
                "alpha_cutoff": ALPHA_CUTOFF,
                "matte_rgba": REVIEW_MATTE,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"wrote {args.output} frames={len(frames)} size={args.frame_size}x{args.frame_size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
