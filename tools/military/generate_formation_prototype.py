#!/usr/bin/env python3
"""Assemble the v2 generative military formation prototype atlas.

The four source sheets are model-generated RGBA bitmaps, each arranged as an
8-column by 4-row action grid. This tool performs slicing, resizing and atlas
packing only. It does not draw or synthesize unit artwork.

V2 enforces a small transparent safety gutter around every generated cell so a
token never samples across an atlas boundary at runtime. The source artwork is
still used verbatim; the gutter only removes generated edge bleed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
PROTOTYPE_DIR = (
    ROOT
    / "Project/project-keynes/assets/military/formations/prototype"
)
SOURCE_DIR = PROTOTYPE_DIR / "source"
DEFAULT_OUTPUT = PROTOTYPE_DIR / "military_formation_prototype_v2.png"
SOURCE_SHEETS = (
    ("foot", SOURCE_DIR / "foot_sheet_v2.png"),
    ("mounted", SOURCE_DIR / "mounted_sheet_v2.png"),
    ("artillery", SOURCE_DIR / "artillery_sheet_v2.png"),
    ("armored", SOURCE_DIR / "armored_sheet_v2.png"),
)

FRAME = 128
FRAME_PADDING = 8
FRAME_COUNT = 8
ACTION_COUNT = 4


def _cell_box(width: int, height: int, column: int, row: int) -> tuple[int, int, int, int]:
    left = round(column * width / FRAME_COUNT)
    right = round((column + 1) * width / FRAME_COUNT)
    top = round(row * height / ACTION_COUNT)
    bottom = round((row + 1) * height / ACTION_COUNT)
    return left, top, right, bottom


def _normalize_cell(source: Image.Image, column: int, row: int) -> Image.Image:
    box = _cell_box(source.width, source.height, column, row)
    tile = source.crop(box).convert("RGBA")
    inner = FRAME - FRAME_PADDING * 2
    tile = tile.resize((inner, inner), Image.Resampling.LANCZOS)
    frame = Image.new("RGBA", (FRAME, FRAME), (0, 0, 0, 0))
    frame.alpha_composite(tile, (FRAME_PADDING, FRAME_PADDING))
    return frame


def _source_manifest(output: Path, atlas: Image.Image) -> dict:
    sheets = []
    for prototype, path in SOURCE_SHEETS:
        payload = path.read_bytes()
        with Image.open(path) as image:
            sheets.append(
                {
                    "prototype": prototype,
                    "path": path.relative_to(ROOT).as_posix(),
                    "width": image.width,
                    "height": image.height,
                    "mode": image.mode,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            )
    return {
        "schema": 2,
        "pipeline": (
            "built-in image generation -> equal-grid slicing "
            "-> transparent-cell padding -> RGBA atlas packing"
        ),
        "art_source": "model-generated raster sheets",
        "projection": "strict vertical orthographic overhead",
        "facing": "east",
        "source_grid": {
            "columns": 8,
            "rows": 4,
            "actions": ["idle", "move", "attack", "hit"],
        },
        "output_frame": {
            "width": FRAME,
            "height": FRAME,
            "transparent_padding_px": FRAME_PADDING,
        },
        "atlas": {
            "path": output.relative_to(ROOT).as_posix(),
            "width": atlas.width,
            "height": atlas.height,
            "mode": atlas.mode,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        },
        "sheets": sheets,
    }


def build_atlas() -> Image.Image:
    sources: list[Image.Image] = []
    try:
        for _, path in SOURCE_SHEETS:
            if not path.exists():
                raise FileNotFoundError(f"missing generated source sheet: {path}")
            sources.append(Image.open(path).convert("RGBA"))

        atlas = Image.new(
            "RGBA",
            (FRAME * FRAME_COUNT, FRAME * ACTION_COUNT * len(SOURCE_SHEETS)),
            (0, 0, 0, 0),
        )
        for prototype_row, source in enumerate(sources):
            for action_row in range(ACTION_COUNT):
                atlas_row = prototype_row * ACTION_COUNT + action_row
                for frame in range(FRAME_COUNT):
                    tile = _normalize_cell(source, frame, action_row)
                    atlas.alpha_composite(tile, (frame * FRAME, atlas_row * FRAME))
        return atlas
    finally:
        for source in sources:
            source.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=SOURCE_DIR / "source_manifest_v2.json",
    )
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    atlas = build_atlas()
    atlas.save(args.output, format="PNG", optimize=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(
        json.dumps(_source_manifest(args.output, atlas), ensure_ascii=True, indent=2) + "\n",
        encoding="utf-8",
    )
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(f"wrote {args.output}")
    print(f"size={atlas.width}x{atlas.height} mode={atlas.mode} sha256={digest}")
    print(f"wrote {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
